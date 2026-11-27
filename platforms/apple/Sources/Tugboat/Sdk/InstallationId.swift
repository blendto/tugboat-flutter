import CommonCrypto
import Foundation

/// The SDK's own installation id (BLE-618), with the rules of Flutter's
/// `TugboatInstallationIdStore` (0.11.5): a random UUID minted on first
/// launch and kept in its own file (`tugboat/installation_id` under the app
/// support directory), so it lasts across launches and app updates and is
/// replaced when app data is removed. It is not in the host's user defaults, so a host
/// that clears them on logout keeps the id.
///
/// On iOS the first value is `identifierForVendor`, so installs that already
/// reported it as `device.id` keep it; a persisted id beats the seed.
/// `identifierForVendor` survives a reinstall while another app from the same
/// vendor stays installed, so the id then survives it too (as in Flutter);
/// otherwise a reinstall mints a new one.
///
/// Reading and writing is blocking disk work: the runtime does it on the
/// engine queue (`EngineHost.postUntimed(type:input:)`), never on the main
/// thread.
///
/// Persistence failures never reach the host: when the file cannot be read or
/// written the id is still returned and stays the same for this process. A
/// failed write is retried on later reads. When several stores race on first
/// launch, the file that ends up on disk wins and every store returns it.
final class InstallationIdStore {
  static let directoryName = "tugboat"
  static let fileName = "installation_id"
  /// Longest id read back from disk; anything longer is treated as corrupt.
  static let maxLength = 128

  private struct Resolved {
    let id: String
    let persisted: Bool
  }

  private let directory: () -> URL?
  private let mint: () -> String
  private let lock = NSLock()
  private var resolved: Resolved?

  /// The process's store, under the app support directory.
  static let shared = InstallationIdStore(directory: {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
  })

  init(directory: @escaping () -> URL?, mint: @escaping () -> String = { UUID().uuidString.lowercased() }) {
    self.directory = directory
    self.mint = mint
  }

  /// The persisted id, minting and persisting one on first call. `seed` is
  /// used instead of a random UUID only when no id has been persisted yet.
  func read(seed: String? = nil) -> String {
    lock.lock()
    defer { lock.unlock() }
    let next: Resolved
    if let previous = resolved {
      // A result that never reached disk is retried; it keeps its id.
      next = previous.persisted ? previous : retry(previous.id)
    } else {
      next = readOrMint(seed: seed)
    }
    resolved = next
    return next.id
  }

  /// A non-empty (after trim) host id wins; otherwise the SDK's own.
  static func resolve(host: String?, sdk: () -> String) -> String {
    let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? sdk() : trimmed
  }

  private func retry(_ id: String) -> Resolved {
    let url = fileURL()
    if let existing = Self.readExisting(url) { return Resolved(id: existing, persisted: true) }
    return store(url, id)
  }

  private func readOrMint(seed: String?) -> Resolved {
    let url = fileURL()
    if let existing = Self.readExisting(url) { return Resolved(id: existing, persisted: true) }
    return store(url, Self.usable(seed) ?? mint())
  }

  /// Persists `id` and returns the id on disk, so a store that lost a
  /// first-launch race adopts the winner's.
  private func store(_ url: URL?, _ id: String) -> Resolved {
    guard let url = url else { return Resolved(id: id, persisted: false) }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if try Self.createExclusive(url, id) { return Resolved(id: id, persisted: true) }
      if let winner = Self.awaitWinner(url) { return Resolved(id: winner, persisted: true) }
      // The file exists but never became a usable id (a torn write from an
      // earlier launch): replace it.
      unlink(url.path)  // fails on a directory, like Dart's File.delete
      let won = try Self.createExclusive(url, id)
      return Resolved(id: won ? id : (Self.readExisting(url) ?? id), persisted: won)
    } catch {
      return Resolved(id: id, persisted: false)
    }
  }

  private func fileURL() -> URL? {
    directory()?.appendingPathComponent(Self.directoryName, isDirectory: true)
      .appendingPathComponent(Self.fileName, isDirectory: false)
  }

  /// Creates the file only if absent (`O_EXCL`) and writes `id` to it;
  /// false when another store created it first.
  private static func createExclusive(_ url: URL, _ id: String) throws -> Bool {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if fd < 0 {
      if errno == EEXIST { return false }
      throw CocoaError(.fileWriteUnknown)
    }
    let bytes = Array(id.utf8)
    var written = 0
    while written < bytes.count {
      let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      if n <= 0 {
        close(fd)
        unlink(url.path)
        throw CocoaError(.fileWriteUnknown)
      }
      written += n
    }
    fsync(fd)
    close(fd)
    return true
  }

  /// Another store created the file; wait briefly for it to finish writing.
  private static func awaitWinner(_ url: URL) -> String? {
    for _ in 0..<5 {
      if let id = readExisting(url) { return id }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return nil
  }

  private static func readExisting(_ url: URL?) -> String? {
    guard let url = url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return usable(text)
  }

  private static func usable(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty, trimmed.count <= maxLength
    else { return nil }
    return trimmed
  }
}

extension TugboatConfig.App {
  /// This app with the installation id a session reports: the host's when
  /// non-blank, else the SDK's own (seeded with `vendorId` on first launch).
  func resolvingInstallationId(
    vendorId: String?, store: InstallationIdStore = .shared
  ) -> TugboatConfig.App {
    var app = self
    app.installationId = InstallationIdStore.resolve(host: installationId) {
      store.read(seed: vendorId)
    }
    return app
  }
}

/// Host entropy for the engine's session and event ids (`session.start.idSeed`).
enum IdSeed {
  /// The `captureSessionId` the engine mints for `seed`: `session-` and the UUIDv4 of the first 16 bytes of
  /// SHA-256(seed bytes || big-endian stream index 0) (core/session-engine session.cpp). Derived here so
  /// `TUGBOAT_LAUNCH` can print it before the engine queue has answered; the tests check it against
  /// `conformance/capture_id_vectors.json` (`seedVectors`), which the engine test reads too.
  ///
  /// INTERIM duplicate of the engine's `IdCounter::next_uuid_id` (core/session-engine/src/session.cpp): the
  /// follow-up on BLE-664 replaces it with a pure engine function. Change both together until then.
  static func sessionId(_ seedHex: String) -> String {
    var bytes = [UInt8]()
    var index = seedHex.startIndex
    while index < seedHex.endIndex {
      let next = seedHex.index(index, offsetBy: 2)
      bytes.append(UInt8(seedHex[index..<next], radix: 16) ?? 0)
      index = next
    }
    bytes += [UInt8](repeating: 0, count: 8)
    var full = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = CC_SHA256(bytes, CC_LONG(bytes.count), &full)
    var digest = Array(full.prefix(16))
    digest[6] = (digest[6] & 0x0f) | 0x40
    digest[8] = (digest[8] & 0x3f) | 0x80
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let h = Array(hex)
    func part(_ a: Int, _ b: Int) -> String { String(h[a..<b]) }
    return "session-\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
  }

  /// 32 random bytes as 64 lowercase hex characters; never reused for
  /// another session.
  static func generate() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
  }
}
