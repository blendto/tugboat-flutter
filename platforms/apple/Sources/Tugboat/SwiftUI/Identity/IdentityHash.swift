import CommonCrypto
import Foundation

/// The engine's `fingerprint.identityParts` hash (fingerprint schema v6),
/// computed in Swift because the engine queue is not synchronous with the
/// main thread. Verified against every `conformance/fingerprint/identity_parts`
/// vector.
///
/// Parts are sorted by key comparing UTF-16 code units (Dart
/// `String.compareTo`; Swift's own `<` compares by canonical equivalence,
/// which would treat NFC and NFD keys as equal), written `key=value`, and
/// joined with `|` without escaping. The fingerprint is the first 16
/// lowercase hex characters of SHA-256 over the UTF-8 bytes, or `""` for no
/// parts. Parts are an ordered list, not a dictionary, for the same reason.
enum IdentityHash {
  static let fingerprintSchemaVersion: Int64 = 6
  private static let hexLength = 16

  static func canonicalString(_ parts: [(key: String, value: String)]) -> String {
    parts
      .sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
      .map { $0.key + "=" + $0.value }
      .joined(separator: "|")
  }

  static func fingerprint(_ parts: [(key: String, value: String)]) -> String {
    guard !parts.isEmpty else { return "" }
    let hex = sha256(Array(canonicalString(parts).utf8)).map { byte -> String in
      let digits = String(byte, radix: 16)
      return byte < 16 ? "0" + digits : digits
    }
    return String(hex.joined().prefix(hexLength))
  }

  private static func sha256(_ bytes: [UInt8]) -> [UInt8] {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    guard let length = CC_LONG(exactly: bytes.count) else { return digest }
    _ = CC_SHA256(bytes, length, &digest)
    return digest
  }
}
