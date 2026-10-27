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
  var attempts: Int
  var processEpoch: String
  var appIdentity: String
  var sdkVersion: String
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
/// written last, so a directory without a readable one is incomplete and
/// deleted as corrupt. On iOS, files and directories get the
/// `completeUntilFirstUserAuthentication` protection class and the outbox
/// is excluded from backup.
///
/// Nothing here throws or traps: a failed write returns false, a failed
/// read is reported as corrupt. Called from the outbox queue only.
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

  /// Every readable entry, and the number of unreadable directories, which
  /// are deleted: no `entry.json`, an unknown `v`, or one that does not
  /// decode.
  func scan() -> (entries: [StoredEntry], corrupt: Int) {
    guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return ([], 0) }
    var entries: [StoredEntry] = []
    var corrupt = 0
    for name in names.sorted() where !name.hasPrefix(".") {
      let directory = root.appendingPathComponent(name, isDirectory: true)
      guard let entry = readEntry(directory), entry.v == OutboxEntry.version, hasPayload(directory, lane: entry.lane)
      else {
        corrupt += 1
        delete(dir: name)
        continue
      }
      entries.append(StoredEntry(dir: name, entry: entry, bytes: size(of: directory)))
    }
    return (entries, corrupt)
  }

  /// The stored payload, or nil when it is unreadable.
  func payload(dir: String, lane: String) -> OutboxPayload? {
    let directory = root.appendingPathComponent(dir, isDirectory: true)
    if lane == "frames" {
      guard let fieldsData = try? Data(contentsOf: directory.appendingPathComponent(OutboxStore.fieldsFile)),
        let stored = try? JSONDecoder().decode(StoredFrame.self, from: fieldsData),
        let jpeg = try? Data(contentsOf: directory.appendingPathComponent(OutboxStore.frameFile))
      else { return nil }
      return .frame(fields: stored.fields.map { FormField(name: $0.name, value: $0.value) }, filename: stored.filename, jpeg: jpeg)
    }
    guard let body = try? Data(contentsOf: directory.appendingPathComponent(OutboxStore.bodyFile)),
      let text = String(data: body, encoding: .utf8)
    else { return nil }
    return .json(text)
  }

  /// The per-install HMAC salt next to the outbox, created on first use;
  /// nil when it can be neither read nor written.
  func salt() -> Data? {
    let url = outboxDirectory.appendingPathComponent(OutboxStore.saltFile)
    if let existing = try? Data(contentsOf: url), existing.count == 32 {
      return existing
    }
    var generator = SystemRandomNumberGenerator()
    let fresh = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
    guard makeDirectory(outboxDirectory), writeAtomically(fresh, to: url) else { return nil }
    excludeFromBackup(outboxDirectory)
    return fresh
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

  private func readEntry(_ directory: URL) -> OutboxEntry? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(OutboxStore.entryFile)) else { return nil }
    return try? JSONDecoder().decode(OutboxEntry.self, from: data)
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
