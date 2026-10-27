import Foundation

/// The host's durable outbox (W11 design section 3, v1 host-only): every
/// collector request the engine sends is written to disk, concurrently with
/// the send, under keys the host derives (`OutboxCapture`); the entry is
/// deleted when the collector accepts it or answers with a status the engine
/// does not retry. Entries the engine never confirmed (a kill mid-retry, an
/// evicted batch, an earlier session) are replayed by the drainer while a
/// later session runs.
///
/// One per process, shared by every session's `OutboxSender` and the
/// drainer. Disk work and the drainer run on the serial `tugboat.outbox`
/// queue; `record` and `answered` take a lock and never wait for the disk,
/// so the engine's requests are never delayed. Nothing here throws or traps:
/// a failed write is counted and logged, and the request is still sent.
final class Outbox {
  /// The drainer's own request deadline (the engine's `jsonTimeoutMs`).
  static let replayTimeoutMs = 15_000

  /// Disk work and the drainer; tests block it to stand in for a slow disk.
  let queue = DispatchQueue(label: "tugboat.outbox", qos: .utility)
  /// Minted when the process starts; names this process's entries.
  let processEpoch: String

  private let store: OutboxStore
  private let wallMs: () -> Int64
  private let log: (String) -> Void
  private let schedule: (_ delayMs: Int, _ work: @escaping () -> Void) -> Void

  /// Any thread.
  private struct Tracking {
    /// This process's latest attempt per key.
    var latest: [String: Int] = [:]
    /// Requests in flight per key (engine and drainer).
    var active: [String: Int] = [:]
    /// The session id of the most recent `http.send` of the newest sender.
    var currentSession: String?
    var currentSessionSender = 0
    var lastSender = 0
    var unkeyed = 0
    /// Bumped by `wipe`; a sender registered before it records nothing more.
    var generation = 0
  }

  private let tracking = Locked(Tracking())
  /// Bumped by `stopReplay`; a drainer send starts only under the lock with
  /// its own token current, so none starts once `stopReplay` returned.
  private let replayToken = Locked(0)
  /// JPEGs of replayed frames, read by the drainer's executor at send time.
  private let replayFrames = Locked([String: Data]())

  // Queue only from here on.
  private var index: [String: StoredEntry]?
  private var identities: [Data: String] = [:]
  private var bounds = OutboxBounds.default
  private var replay: Replay?
  private var counts = OutboxPassCounts()
  private var writeFailures = 0
  /// The salt exists but cannot be read: no writes and no replay for the
  /// rest of the process (the salt is never overwritten).
  private var disabled = false
  /// Entries the last scan could not read; the next pass scans again.
  private var unreadableAtScan = 0

  private final class Replay {
    let token: Int
    let sender: HTTPSender
    let context: OutboxContext
    var inFlight = false
    var backingOff = false
    var passes = 0
    /// Payloads this pass could not read; retried next pass.
    var skipped = Set<String>()

    init(token: Int, sender: HTTPSender, context: OutboxContext) {
      self.token = token
      self.sender = sender
      self.context = context
    }
  }

  init(
    store: OutboxStore,
    processEpoch: String = Outbox.mintEpoch(),
    wallMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
    log: @escaping (String) -> Void = HostLog.outbox,
    schedule: ((_ delayMs: Int, _ work: @escaping () -> Void) -> Void)? = nil
  ) {
    self.store = store
    self.processEpoch = processEpoch
    self.wallMs = wallMs
    self.log = log
    let queue = self.queue
    self.schedule = schedule ?? { delayMs, work in queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work) }
  }

  /// The process's outbox in `Application Support`, or nil when that
  /// directory is unavailable. Nothing touches the disk until it is used.
  static let shared: Outbox? = OutboxStore.defaultRoot().map { Outbox(store: OutboxStore(root: $0)) }

  static func mintEpoch() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
  }

  /// A sender's id, and the wipe generation it records for.
  struct SenderRegistration {
    let id: Int
    let generation: Int
  }

  /// A new sender; the newest sender's sends set the current session, and
  /// a sender records only until the next `wipe`.
  func registerSender() -> SenderRegistration {
    tracking.withLock { (state: inout Tracking) -> SenderRegistration in
      state.lastSender += 1
      return SenderRegistration(id: state.lastSender, generation: state.generation)
    }
  }

  // MARK: - Engine requests (any thread)

  /// Captures `request` for the outbox, on the engine queue at dispatch
  /// (frame bytes are read now, before the engine can release them), and
  /// queues its write; nil when it cannot be keyed, or the sender was
  /// registered before the last `wipe` (then sent without an entry). Never
  /// waits for the disk.
  func record(
    _ request: HTTPRequest, sender: SenderRegistration, context: OutboxContext, frameBytes: (_ handle: String) -> Data?
  ) -> OutboxAttempt? {
    guard tracking.withLock({ $0.generation }) == sender.generation else { return nil }
    guard let units = OutboxCapture.units(request, frameBytes: frameBytes) else {
      tracking.withLock { $0.unkeyed += 1 }
      return nil
    }
    let now = wallMs()
    // The write is queued under the lock, as `wipe` queues its delete: a
    // write that passed the generation check is always queued before the
    // wipe that ends its generation, so it never lands after it.
    return tracking.withLock { (state: inout Tracking) -> OutboxAttempt? in
      guard state.generation == sender.generation else { return nil }
      var numbered: [OutboxAttempt.Unit] = []
      for unit in units {
        let number = (state.latest[unit.key] ?? 0) + 1
        state.latest[unit.key] = number
        state.active[unit.key, default: 0] += 1
        numbered.append(OutboxAttempt.Unit(key: unit.key, number: number))
      }
      var changed = false
      if sender.id >= state.currentSessionSender, let sessionId = units.first?.sessionId,
        state.currentSession != sessionId
      {
        state.currentSession = sessionId
        state.currentSessionSender = sender.id
        changed = true
      }
      let sessionChanged = changed
      queue.async {
        self.write(units, context: context, now: now)
        if sessionChanged {
          self.drainPass()
        }
      }
      return OutboxAttempt(units: numbered)
    }
  }

  /// The answer to an engine request recorded as `attempt`: an accepted or
  /// dropped answer deletes each unit's entry, after its write, unless a
  /// later attempt for that key was sent since.
  func answered(_ attempt: OutboxAttempt, outcome: TransportOutcome) {
    tracking.withLock { state in
      for unit in attempt.units {
        Outbox.release(unit.key, in: &state)
      }
    }
    guard SessionEndWatcher.isFinal(outcome) else { return }
    queue.async {
      let latest = self.tracking.current.latest
      for unit in attempt.units where latest[unit.key] == unit.number {
        self.remove(dir: self.dirName(key: unit.key, epoch: self.processEpoch))
      }
    }
  }

  /// Returns once every write queued before this call is on disk. Not on
  /// the outbox queue.
  func waitForWrites() {
    queue.sync {}
  }

  /// Deletes every pending entry, after the writes queued before it
  /// (`TugboatConfig.durableOutbox` false at `start`, `clearPendingData`).
  /// Senders registered before it record nothing more, so an engine still
  /// draining (after `stop`) cannot write evidence back.
  func wipe() {
    tracking.withLock { (state: inout Tracking) in
      state.generation += 1
      queue.async {
        self.store.wipe()
        // Rescanned on next use, so entries a failed wipe left stay visible.
        self.index = nil
      }
    }
  }

  /// At every `start` with the outbox on, dormant or not: deletes corrupt
  /// entries and those past the max age, and enforces the size and count
  /// bounds. Disk only; it sends nothing.
  func sweepAtStart(bounds: OutboxBounds) {
    queue.async {
      self.bounds = bounds
      self.index = nil
      self.expireByAge()
      self.enforceBounds()
      self.log(self.counts.line(bytesOnDisk: self.bytesOnDisk()).replacingOccurrences(of: "outbox pass", with: "outbox sweep"))
      self.counts = OutboxPassCounts()
    }
  }

  // MARK: - Drainer

  /// Starts replaying orphans with `sender` (the drainer's own executor):
  /// one pass now, another whenever the current session changes. Only while
  /// a session runs.
  func startReplay(sender: HTTPSender, context: OutboxContext) {
    let token = replayToken.withLock { (token: inout Int) -> Int in
      token += 1
      return token
    }
    queue.async {
      self.replay?.sender.close()
      self.replay = Replay(token: token, sender: sender, context: context)
      self.bounds = context.bounds
      self.drainPass()
    }
  }

  /// Stops the drainer: no drainer request starts after this returns. A
  /// replay in flight finishes, and its answer is still applied.
  func stopReplay() {
    replayToken.withLock { $0 += 1 }
    queue.async {
      self.replay?.sender.close()
      self.replay = nil
    }
  }

  /// The drainer executor's frame bytes.
  func replayFrame(_ handle: String) -> Data? {
    replayFrames.current[handle]
  }

  // MARK: - Tests

  /// Counts and state after the queued work ran.
  struct Snapshot {
    var entries: [StoredEntry]
    var writeFailures: Int
    var unkeyed: Int
    var currentSession: String?
    var activeKeys: Set<String>
    var replayPasses: Int
  }

  func snapshot() -> Snapshot {
    queue.sync {
      let state = tracking.current
      return Snapshot(
        entries: loadedIndex().values.sorted { $0.dir < $1.dir }, writeFailures: writeFailures, unkeyed: state.unkeyed,
        currentSession: state.currentSession, activeKeys: Set(state.active.keys), replayPasses: replay?.passes ?? 0)
    }
  }

  // MARK: - Queue: writes

  private static func release(_ key: String, in state: inout Tracking) {
    let remaining = (state.active[key] ?? 1) - 1
    state.active[key] = remaining > 0 ? remaining : nil
  }

  func dirName(key: String, epoch: String) -> String {
    "\(epoch)-\(OutboxDigest.sha256Hex(Data(key.utf8)).prefix(20))"
  }

  private func write(_ units: [OutboxUnit], context: OutboxContext, now: Int64) {
    var entries = loadedIndex()
    bounds = context.bounds
    guard let identity = identity(context) else {
      fail(units.count, "outbox: no readable salt; \(units.count) entries not written")
      return
    }
    for unit in units {
      let dir = dirName(key: unit.key, epoch: processEpoch)
      if var stored = entries[dir] {
        stored.entry.attempts = saturatingIncrement(stored.entry.attempts)
        stored.entry.lastAttemptWallMs = now
        var body: String?
        if case let .json(text) = unit.payload { body = text }
        if let size = store.update(dir: dir, entry: stored.entry, body: body) {
          stored.bytes = size
          entries[dir] = stored
        } else {
          fail(1, "outbox: could not update an entry (\(unit.lane))")
        }
        continue
      }
      let entry = OutboxEntry(
        v: OutboxEntry.version, key: unit.key, lane: unit.lane, path: unit.path, sessionId: unit.sessionId,
        createdAtWallMs: now, lastAttemptWallMs: now, attempts: 1, processEpoch: processEpoch,
        appIdentity: identity, sdkVersion: context.sdkVersion)
      if let size = store.create(dir: dir, entry: entry, payload: unit.payload) {
        entries[dir] = StoredEntry(dir: dir, entry: entry, bytes: size)
      } else {
        store.delete(dir: dir)
        fail(1, "outbox: could not write an entry (\(unit.lane))")
      }
    }
    index = entries
    enforceBounds()
  }

  private func fail(_ count: Int, _ message: String) {
    writeFailures += count
    log(message)
  }

  /// nil, and the outbox off for this process, when the salt exists but
  /// cannot be read.
  private func identity(_ context: OutboxContext) -> String? {
    if disabled { return nil }
    if let known = identities[context.identityInput] { return known }
    guard case let .salt(salt) = store.salt() else {
      disabled = true
      log("outbox: the salt cannot be read; the outbox is off for this process")
      return nil
    }
    let identity = OutboxDigest.hmacSHA256Hex(key: salt, message: context.identityInput)
    identities[context.identityInput] = identity
    return identity
  }

  private func loadedIndex() -> [String: StoredEntry] {
    if let index = index { return index }
    let scanned = store.scan()
    counts.corrupt += scanned.corrupt
    unreadableAtScan = scanned.unreadable
    let loaded = Dictionary(scanned.entries.map { ($0.dir, $0) }, uniquingKeysWith: { first, _ in first })
    index = loaded
    return loaded
  }

  private func remove(dir: String) {
    guard index?.removeValue(forKey: dir) != nil else { return }
    store.delete(dir: dir)
  }

  private func isOrphan(_ stored: StoredEntry, _ state: Tracking) -> Bool {
    if stored.entry.processEpoch != processEpoch { return true }
    guard let current = state.currentSession else { return false }
    return stored.entry.sessionId != current
  }

  /// Over a bound: orphans first, oldest first, frames before events; never
  /// a key with a request in flight, never a lifecycle entry (age only).
  private func enforceBounds() {
    var entries = loadedIndex()
    let state = tracking.current
    var total = entries.values.reduce(0) { $0 + $1.bytes }
    while total > bounds.maxBytes || entries.count > bounds.maxEntries {
      let victims = entries.values.filter { $0.entry.lane != "lifecycle" && state.active[$0.entry.key] == nil }
      guard let victim = victims.min(by: { evictionOrder($0, $1, state) }) else { break }
      entries.removeValue(forKey: victim.dir)
      store.delete(dir: victim.dir)
      total -= victim.bytes
      counts.evicted += 1
    }
    index = entries
  }

  private func evictionOrder(_ a: StoredEntry, _ b: StoredEntry, _ state: Tracking) -> Bool {
    let rank = { (s: StoredEntry) -> (Int, Int) in (self.isOrphan(s, state) ? 0 : 1, s.entry.lane == "frames" ? 0 : 1) }
    if rank(a) != rank(b) { return rank(a) < rank(b) }
    return replayOrder(a, b)
  }

  private func replayOrder(_ a: StoredEntry, _ b: StoredEntry) -> Bool {
    if a.entry.createdAtWallMs != b.entry.createdAtWallMs { return a.entry.createdAtWallMs < b.entry.createdAtWallMs }
    return a.entry.key < b.entry.key
  }

  // MARK: - Queue: drainer

  /// Deletes what must not be sent (too old, too many attempts, another
  /// identity), then sends the oldest orphan without a request in flight;
  /// its answer continues the pass. Logs one line when a pass ends.
  private func drainPass() {
    guard let replay = replay, !replay.inFlight, !replay.backingOff else { return }
    // Fails closed: without the identity nothing is checked, so nothing is sent.
    guard let identity = identity(replay.context) else { return }
    if unreadableAtScan > 0 {
      // Entries the last scan could not read are tried again.
      index = nil
    }
    sweep(identity: identity)
    while true {
      let state = tracking.current
      let candidates = loadedIndex().values.filter {
        isOrphan($0, state) && state.active[$0.entry.key] == nil && !replay.skipped.contains($0.dir)
      }
      guard let next = candidates.min(by: replayOrder) else {
        endPass(replay)
        return
      }
      switch store.payload(dir: next.dir, lane: next.entry.lane) {
      case let .payload(payload):
        send(next, payload: payload, replay: replay)
        return
      case .unreadable:
        replay.skipped.insert(next.dir)
      case .corrupt:
        remove(dir: next.dir)
        counts.corrupt += 1
      }
    }
  }

  /// Deletes, without sending, entries past the max age, of another app
  /// identity, or orphans whose replays reached `maxAttempts`. Never a key
  /// with a request in flight.
  private func sweep(identity: String) {
    expireByAge()
    let state = tracking.current
    for stored in loadedIndex().values where state.active[stored.entry.key] == nil {
      if stored.entry.appIdentity != identity {
        remove(dir: stored.dir)
        counts.identityMismatch += 1
      } else if isOrphan(stored, state) && stored.entry.replays >= bounds.maxAttempts {
        remove(dir: stored.dir)
        counts.expired += 1
      }
    }
    enforceBounds()
  }

  private func expireByAge() {
    let state = tracking.current
    let now = wallMs()
    for stored in loadedIndex().values where state.active[stored.entry.key] == nil {
      let (age, overflow) = now.subtractingReportingOverflow(stored.entry.createdAtWallMs)
      if overflow || age > Int64(bounds.maxAgeMs) {
        remove(dir: stored.dir)
        counts.expired += 1
      }
    }
  }

  private func bytesOnDisk() -> Int {
    loadedIndex().values.reduce(0) { $0 + $1.bytes }
  }

  /// Counts the replay on disk first, then sends it unless `stopReplay` ran
  /// since; a replay that never started is rolled back, so start/stop races
  /// cannot expire an entry that was never sent.
  private func send(_ entry: StoredEntry, payload: OutboxPayload, replay: Replay) {
    var stored = entry
    stored.entry.replays = saturatingIncrement(stored.entry.replays)
    stored.entry.attempts = saturatingIncrement(stored.entry.attempts)
    stored.entry.lastAttemptWallMs = wallMs()
    stored.bytes = store.update(dir: stored.dir, entry: stored.entry, body: nil) ?? stored.bytes
    index?[stored.dir] = stored
    let dir = stored.dir
    let key = stored.entry.key
    let body: HTTPBody
    switch payload {
    case let .json(text):
      body = .json(text)
    case let .frame(fields, filename, jpeg):
      replayFrames.withLock { $0 = [dir: jpeg] }
      body = .multipart(fields: fields, frames: [FramePart(handle: stored.dir, filename: filename)])
    }
    var request = HTTPRequest(
      requestId: "outbox-\(stored.dir)", lane: stored.entry.lane, path: stored.entry.path,
      timeoutMs: Outbox.replayTimeoutMs, body: body)
    request.deliveryKey = key
    replay.inFlight = true
    tracking.withLock { $0.active[key, default: 0] += 1 }
    let started = replayToken.withLock { (token: inout Int) -> Bool in
      guard token == replay.token else { return false }
      replay.sender.send(request) { outcome in
        self.queue.async { self.replayAnswered(dir, key: key, outcome: outcome, replay: replay) }
      }
      return true
    }
    if !started {
      replay.inFlight = false
      tracking.withLock { Outbox.release(key, in: &$0) }
      replayFrames.withLock { $0.removeValue(forKey: dir) }
      var restored = entry
      restored.bytes = store.update(dir: dir, entry: entry.entry, body: nil) ?? entry.bytes
      index?[dir] = restored
    }
  }

  private func replayAnswered(_ dir: String, key: String, outcome: TransportOutcome, replay: Replay) {
    replay.inFlight = false
    replayFrames.withLock { $0.removeValue(forKey: dir) }
    tracking.withLock { Outbox.release(key, in: &$0) }
    if SessionEndWatcher.isFinal(outcome) {
      remove(dir: dir)
      counts.replayed += 1
    } else if let stored = index?[dir] {
      if stored.entry.replays >= bounds.maxAttempts {
        remove(dir: dir)
        counts.expired += 1
      } else {
        backOff(replay, replays: stored.entry.replays, outcome: outcome)
        return
      }
    }
    if self.replay === replay {
      drainPass()
    }
  }

  private func backOff(_ replay: Replay, replays: Int, outcome: TransportOutcome) {
    var retryAfter: String?
    if case let .http(_, _, value) = outcome { retryAfter = value }
    let delay = OutboxBackoff.delayMs(attempts: replays, retryAfter: retryAfter, nowWallMs: wallMs())
    endPass(replay)
    replay.backingOff = true
    schedule(delay) { [weak self] in
      guard let outbox = self else { return }
      outbox.queue.async {
        replay.backingOff = false
        if outbox.replay === replay {
          outbox.drainPass()
        }
      }
    }
  }

  private func endPass(_ replay: Replay) {
    replay.passes += 1
    replay.skipped.removeAll()
    log(counts.line(bytesOnDisk: bytesOnDisk()))
    counts = OutboxPassCounts()
  }
}
