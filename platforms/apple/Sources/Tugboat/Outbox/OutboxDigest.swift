import CommonCrypto
import Foundation

/// SHA-256 and HMAC-SHA-256 for outbox keys, directory names, and the
/// salted app identity, as lowercase hex.
enum OutboxDigest {
  static func sha256Hex(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    let bytes = [UInt8](data)
    _ = CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
    return hex(digest)
  }

  static func hmacSHA256Hex(key: Data, message: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    let keyBytes = [UInt8](key)
    let messageBytes = [UInt8](message)
    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes, keyBytes.count, messageBytes, messageBytes.count, &digest)
    return hex(digest)
  }

  private static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
