import Foundation

/// `entry.json`: what the drainer needs to send an entry again without an
/// engine (W11 design section 3.2). Never the API key: `appIdentity` is a
/// salted HMAC of the collector base URL, app id, and API key.
struct OutboxEntry: Codable, Equatable {
  static let version = 1

  var v: Int
  var key: String
  var lane: String
  var path: String
  var sessionId: String
  var createdAtWallMs: Int64
  var lastAttemptWallMs: Int64
  /// Every send under this key, by the engine and the drainer (diagnostic).
  var attempts: Int
  var processEpoch: String
  var appIdentity: String
  var sdkVersion: String
  /// Drainer replays only; `maxAttempts` applies to this, so engine retries
  /// (one per flush pass while offline) never use it up. Missing reads as 0.
  var replays: Int = 0

  /// Largest wall time or count accepted from disk; anything outside
  /// `0...limit` makes the entry corrupt, so arithmetic on it cannot trap.
  static let limit: Int64 = 1 << 52

  /// Every number is in range.
  var isValid: Bool {
    let range = 0...OutboxEntry.limit
    return range.contains(createdAtWallMs) && range.contains(lastAttemptWallMs)
      && range.contains(Int64(attempts)) && range.contains(Int64(replays))
  }
}

extension OutboxEntry {
  private enum CodingKeys: String, CodingKey {
    case v, key, lane, path, sessionId, createdAtWallMs, lastAttemptWallMs, attempts, processEpoch, appIdentity
    case sdkVersion, replays
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    v = try container.decode(Int.self, forKey: .v)
    key = try container.decode(String.self, forKey: .key)
    lane = try container.decode(String.self, forKey: .lane)
    path = try container.decode(String.self, forKey: .path)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    createdAtWallMs = try container.decode(Int64.self, forKey: .createdAtWallMs)
    lastAttemptWallMs = try container.decode(Int64.self, forKey: .lastAttemptWallMs)
    attempts = try container.decode(Int.self, forKey: .attempts)
    processEpoch = try container.decode(String.self, forKey: .processEpoch)
    appIdentity = try container.decode(String.self, forKey: .appIdentity)
    sdkVersion = try container.decode(String.self, forKey: .sdkVersion)
    replays = try container.decodeIfPresent(Int.self, forKey: .replays) ?? 0
  }
}

/// A count bumped from disk data, saturating instead of trapping.
func saturatingIncrement(_ value: Int) -> Int {
  value < Int.max ? value + 1 : value
}

/// What reading a stored payload came to.
enum OutboxPayloadRead: Equatable {
  case payload(OutboxPayload)
  /// A file is there but cannot be read now (for example protected before
  /// the first unlock): skipped, never deleted.
  case unreadable
  /// Missing or undecodable: deleted.
  case corrupt
}

/// The per-install salt.
enum OutboxSalt: Equatable {
  case salt(Data)
  /// The file exists but cannot be read, or is not a salt: the outbox is
  /// off for this process and the file is never overwritten.
  case unavailable
}

/// One stored entry: its directory name, metadata, and size on disk.
struct StoredEntry: Equatable {
  let dir: String
  var entry: OutboxEntry
  var bytes: Int
}

/// The outbox on disk: one directory per entry under `root`
/// (`…/outbox/v1`), holding `entry.json` and either `body` (JSON lanes) or
/// `fields.json` plus `frame.jpg` (one frame). Every file is written to a
/// temporary file, synced, then renamed over the target; `entry.json` is
/// written last, so a directory without one is incomplete and deleted as
/// corrupt. A file that exists but cannot be read (Data Protection before
/// the first unlock) is skipped, never deleted. On iOS, files and directories get the
/// `completeUntilFirstUserAuthentication` protection class and the outbox
/// is excluded from backup.
///
/// Nothing here throws or traps: a failed write returns false; only a
/// missing or undecodable file, an unknown `v`, or out-of-range numbers make
/// an entry corrupt. Called from the outbox queue only.
final class OutboxStore {
  static let entryFile = "entry.json"
  static let bodyFile = "body"
  static let fieldsFile = "fields.json"
  static let frameFile = "frame.jpg"
  static let saltFile = "salt"

  /// `…/outbox/v1`.
  let root: URL
  private let fileManager = FileManager.default

  init(root: URL) {
    self.root = root
  }

  /// `Application Support/Tugboat/outbox/v1`, or nil when the directory is
  /// unavailable.
  static func defaultRoot() -> URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    return support.appendingPathComponent("Tugboat/outbox/v1", isDirectory: true)
  }

  /// `…/outbox`, which holds the salt and `v1`.
  private var outboxDirectory: URL {
    root.deletingLastPathComponent()
  }

  // MARK: - Writing

  /// Writes a new entry: its payload files, then `entry.json`.
  func create(dir: String, entry: OutboxEntry, payload: OutboxPayload) -> Int? {
    guard ensureRoot() else { return nil }
    let directory = root.appendingPathComponent(dir, isDirectory: true)
    guard makeDirectory(directory) else { return nil }
    var files: [(String, Data)] = []
    switch payload {
    case let .json(text):
      files.append((OutboxStore.bodyFile, Data(text.utf8)))
    case let .frame(fields, filename, jpeg):
      guard let encoded = try? JSONEncoder().encode(StoredFrame(fields: fields, filename: filename)) else { return nil }
      files.append((OutboxStore.fieldsFile, encoded))
      files.append((OutboxStore.frameFile, jpeg))
    }
    guard let entryData = try? JSONEncoder().encode(entry) else { return nil }
    files.append((OutboxStore.entryFile, entryData))
    for (name, data) in files {
      guard writeAtomically(data, to: directory.appendingPathComponent(name)) else { return nil }
    }
    return files.reduce(0) { $0 + $1.1.count }
  }

  /// Replaces `entry.json` and, for a JSON lane, `body` (the entry holds the
  /// last body sent under its key). Returns the entry's new size.
  func update(dir: String, entry: OutboxEntry, body: String?) -> Int? {
    let directory = root.appendingPathComponent(dir, isDirectory: true)
    if let body = body {
      guard writeAtomically(Data(body.utf8), to: directory.appendingPathComponent(OutboxStore.bodyFile)) else {
        return nil
      }
    }
    guard let entryData = try? JSONEncoder().encode(entry),
      writeAtomically(entryData, to: directory.appendingPathComponent(OutboxStore.entryFile))
    else { return nil }
    return size(of: directory)
  }

  func delete(dir: String) {
    try? fileManager.removeItem(at: root.appendingPathComponent(dir, isDirectory: true))
  }

  /// Deletes every entry (the salt stays).
  func wipe() {
    guard fileManager.fileExists(atPath: root.path) else { return }
    do {
      try fileManager.removeItem(at: root)
    } catch {
      HostLog.warning("outbox: could not delete pending entries: \((error as NSError).code)")
    }
  }

  // MARK: - Reading

  /// What one scan found: readable entries, the corrupt directories it
  /// deleted (no `entry.json`, no payload, an undecodable file, an unknown
  /// `v`, numbers out of range), and how many it skipped as unreadable.
  struct Scan {
    var entries: [StoredEntry] = []
    var corrupt = 0
    var unreadable = 0
  }

  func scan() -> Scan {
    var result = Scan()
    guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return result }
    for name in names.sorted() where !name.hasPrefix(".") {
      let directory = root.appendingPathComponent(name, isDirectory: true)
      switch readEntry(directory) {
      case .unreadable:
        result.unreadable += 1
      case let .entry(entry) where entry.v == OutboxEntry.version && entry.isValid && hasPayload(directory, lane: entry.lane):
        result.entries.append(StoredEntry(dir: name, entry: entry, bytes: size(of: directory)))
      default:
        result.corrupt += 1
        delete(dir: name)
      }
    }
    return result
  }

  /// The stored payload.
  func payload(dir: String, lane: String) -> OutboxPayloadRead {
    let directory = root.appendingPathComponent(dir, isDirectory: true)
    if lane == "frames" {
      guard case let .data(fieldsData) = read(directory.appendingPathComponent(OutboxStore.fieldsFile)),
        case let .data(jpeg) = read(directory.appendingPathComponent(OutboxStore.frameFile))
      else {
        return readFailure(directory, [OutboxStore.fieldsFile, OutboxStore.frameFile])
      }
      guard let stored = try? JSONDecoder().decode(StoredFrame.self, from: fieldsData) else { return .corrupt }
      return .payload(
        .frame(fields: stored.fields.map { FormField(name: $0.name, value: $0.value) }, filename: stored.filename, jpeg: jpeg))
    }
    guard case let .data(body) = read(directory.appendingPathComponent(OutboxStore.bodyFile)) else {
      return readFailure(directory, [OutboxStore.bodyFile])
    }
    guard let text = String(data: body, encoding: .utf8) else { return .corrupt }
    return .payload(.json(text))
  }

  /// The per-install HMAC salt next to the outbox, created on first use;
  /// nil when it can be neither read nor written.
  func salt() -> OutboxSalt {
    let url = outboxDirectory.appendingPathComponent(OutboxStore.saltFile)
    switch read(url) {
    case let .data(existing):
      return existing.count == 32 ? .salt(existing) : .unavailable
    case .unreadable:
      return .unavailable
    case .missing:
      break
    }
    var generator = SystemRandomNumberGenerator()
    let fresh = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
    guard makeDirectory(outboxDirectory), writeAtomically(fresh, to: url) else { return .unavailable }
    excludeFromBackup(outboxDirectory)
    return .salt(fresh)
  }

  // MARK: - Files

  private struct StoredFrame: Codable {
    struct Field: Codable {
      let name: String
      let value: String
    }

    let fields: [Field]
    let filename: String

    init(fields: [FormField], filename: String) {
      self.fields = fields.map { Field(name: $0.name, value: $0.value) }
      self.filename = filename
    }
  }

  private enum FileRead {
    case data(Data)
    case missing
    case unreadable
  }

  private enum EntryRead {
    case entry(OutboxEntry)
    case corrupt
    case unreadable
  }

  /// A missing file is told apart from one that exists but cannot be read.
  private func read(_ url: URL) -> FileRead {
    guard fileManager.fileExists(atPath: url.path) else { return .missing }
    guard let data = try? Data(contentsOf: url) else { return .unreadable }
    return .data(data)
  }

  private func readEntry(_ directory: URL) -> EntryRead {
    switch read(directory.appendingPathComponent(OutboxStore.entryFile)) {
    case let .data(data):
      guard let entry = try? JSONDecoder().decode(OutboxEntry.self, from: data) else { return .corrupt }
      return .entry(entry)
    case .missing:
      return .corrupt
    case .unreadable:
      return .unreadable
    }
  }

  /// `.unreadable` when one of `names` exists but cannot be read, else
  /// `.corrupt` (one is missing).
  private func readFailure(_ directory: URL, _ names: [String]) -> OutboxPayloadRead {
    let unreadable = names.contains { name in
      if case .unreadable = read(directory.appendingPathComponent(name)) { return true }
      return false
    }
    return unreadable ? .unreadable : .corrupt
  }

  private func hasPayload(_ directory: URL, lane: String) -> Bool {
    let names = lane == "frames" ? [OutboxStore.fieldsFile, OutboxStore.frameFile] : [OutboxStore.bodyFile]
    return names.allSatisfy { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
  }

  private func size(of directory: URL) -> Int {
    guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
    return names.reduce(0) { total, name in
      let attributes = try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
      return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
    }
  }

  private func ensureRoot() -> Bool {
    guard makeDirectory(root) else { return false }
    excludeFromBackup(outboxDirectory)
    return true
  }

  private func makeDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      return isDirectory.boolValue
    }
    do {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: OutboxStore.protection)
      return true
    } catch {
      return false
    }
  }

  /// Temporary file, `fsync`, then `rename` over `url`.
  private func writeAtomically(_ data: Data, to url: URL) -> Bool {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
    guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: OutboxStore.protection) else {
      return false
    }
    if let handle = FileHandle(forUpdatingAtPath: temporary.path) {
      handle.synchronizeFile()
      handle.closeFile()
    }
    guard rename(temporary.path, url.path) == 0 else {
      try? fileManager.removeItem(at: temporary)
      return false
    }
    return true
  }

  private func excludeFromBackup(_ url: URL) {
    #if os(iOS)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var target = url
      try? target.setResourceValues(values)
    #endif
  }

  /// Data Protection for evidence at rest (W11 design section 3.5).
  private static var protection: [FileAttributeKey: Any]? {
    #if os(iOS)
      return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    #else
      return nil
    #endif
  }
}
