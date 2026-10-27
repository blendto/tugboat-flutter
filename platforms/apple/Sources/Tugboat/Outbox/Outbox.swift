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

  private final class Replay {
    let token: Int
    let sender: HTTPSender
    let context: OutboxContext
    var inFlight = false
    var backingOff = false
    var passes = 0

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

  /// A new sender id; the newest sender's sends set the current session.
  func registerSender() -> Int {
    tracking.withLock { (state: inout Tracking) -> Int in
      state.lastSender += 1
      return state.lastSender
    }
  }

  // MARK: - Engine requests (any thread)

  /// Captures `request` for the outbox, on the engine queue at dispatch
  /// (frame bytes are read now, before the engine can release them), and
  /// queues its write; nil when it cannot be keyed (then sent without an
  /// entry). Never waits for the disk.
  func record(
    _ request: HTTPRequest, sender: Int, context: OutboxContext, frameBytes: (_ handle: String) -> Data?
  ) -> OutboxAttempt? {
    guard let units = OutboxCapture.units(request, frameBytes: frameBytes) else {
      tracking.withLock { $0.unkeyed += 1 }
      return nil
    }
    let now = wallMs()
    let (attempt, sessionChanged) = tracking.withLock { (state: inout Tracking) -> (OutboxAttempt, Bool) in
      var numbered: [OutboxAttempt.Unit] = []
      for unit in units {
        let number = (state.latest[unit.key] ?? 0) + 1
        state.latest[unit.key] = number
        state.active[unit.key, default: 0] += 1
        numbered.append(OutboxAttempt.Unit(key: unit.key, number: number))
      }
      var changed = false
      if sender >= state.currentSessionSender, let sessionId = units.first?.sessionId, state.currentSession != sessionId {
        state.currentSession = sessionId
        state.currentSessionSender = sender
        changed = true
      }
      return (OutboxAttempt(units: numbered), changed)
    }
    queue.async {
      self.write(units, context: context, now: now)
      if sessionChanged {
        self.drainPass()
      }
    }
    return attempt
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
  func wipe() {
    queue.async {
      self.store.wipe()
      self.index = [:]
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
      fail(units.count, "outbox: no identity salt; \(units.count) entries not written")
      return
    }
    for unit in units {
      let dir = dirName(key: unit.key, epoch: processEpoch)
      if var stored = entries[dir] {
        stored.entry.attempts += 1
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

  private func identity(_ context: OutboxContext) -> String? {
    if let known = identities[context.identityInput] { return known }
    guard let salt = store.salt() else { return nil }
    let identity = OutboxDigest.hmacSHA256Hex(key: salt, message: context.identityInput)
    identities[context.identityInput] = identity
    return identity
  }

  private func loadedIndex() -> [String: StoredEntry] {
    if let index = index { return index }
    let scanned = store.scan()
    counts.corrupt += scanned.corrupt
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
    sweep(replay)
    let state = tracking.current
    let candidates = loadedIndex().values.filter { isOrphan($0, state) && state.active[$0.entry.key] == nil }
    guard let next = candidates.min(by: replayOrder) else {
      endPass(replay)
      return
    }
    guard let payload = store.payload(dir: next.dir, lane: next.entry.lane) else {
      remove(dir: next.dir)
      counts.corrupt += 1
      drainPass()
      return
    }
    send(next, payload: payload, replay: replay)
  }

  private func sweep(_ replay: Replay) {
    let entries = loadedIndex()
    let state = tracking.current
    let now = wallMs()
    let identity = self.identity(replay.context)
    for stored in entries.values where state.active[stored.entry.key] == nil {
      if now - stored.entry.createdAtWallMs > Int64(bounds.maxAgeMs) {
        remove(dir: stored.dir)
        counts.expired += 1
      } else if let identity = identity, stored.entry.appIdentity != identity {
        remove(dir: stored.dir)
        counts.identityMismatch += 1
      } else if isOrphan(stored, state) && stored.entry.attempts >= bounds.maxAttempts {
        remove(dir: stored.dir)
        counts.expired += 1
      }
    }
    enforceBounds()
  }

  private func send(_ stored: StoredEntry, payload: OutboxPayload, replay: Replay) {
    let key = stored.entry.key
    let body: HTTPBody
    switch payload {
    case let .json(text):
      body = .json(text)
    case let .frame(fields, filename, jpeg):
      replayFrames.withLock { $0 = [stored.dir: jpeg] }
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
        self.queue.async { self.replayAnswered(stored.dir, key: key, outcome: outcome, replay: replay) }
      }
      return true
    }
    if !started {
      replay.inFlight = false
      tracking.withLock { Outbox.release(key, in: &$0) }
    }
  }

  private func replayAnswered(_ dir: String, key: String, outcome: TransportOutcome, replay: Replay) {
    replay.inFlight = false
    replayFrames.withLock { $0.removeValue(forKey: dir) }
    tracking.withLock { Outbox.release(key, in: &$0) }
    if SessionEndWatcher.isFinal(outcome) {
      remove(dir: dir)
      counts.replayed += 1
    } else if var stored = index?[dir] {
      stored.entry.attempts += 1
      stored.entry.lastAttemptWallMs = wallMs()
      if stored.entry.attempts >= bounds.maxAttempts {
        remove(dir: dir)
        counts.expired += 1
      } else {
        stored.bytes = store.update(dir: dir, entry: stored.entry, body: nil) ?? stored.bytes
        index?[dir] = stored
        backOff(replay, attempts: stored.entry.attempts, outcome: outcome)
        return
      }
    }
    if self.replay === replay {
      drainPass()
    }
  }

  private func backOff(_ replay: Replay, attempts: Int, outcome: TransportOutcome) {
    var retryAfter: String?
    if case let .http(_, _, value) = outcome { retryAfter = value }
    let delay = OutboxBackoff.delayMs(attempts: attempts, retryAfter: retryAfter, nowWallMs: wallMs())
    endPass(replay)
    replay.backingOff = true
    schedule(delay) { [weak self] in
      self?.queue.async {
        replay.backingOff = false
        if self?.replay === replay {
          self?.drainPass()
        }
      }
    }
  }

  private func endPass(_ replay: Replay) {
    replay.passes += 1
    let bytes = loadedIndex().values.reduce(0) { $0 + $1.bytes }
    log(counts.line(bytesOnDisk: bytes))
    counts = OutboxPassCounts()
  }
}
