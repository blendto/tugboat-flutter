import CommonCrypto
import CryptoKit
import Foundation

enum ContentHash {
  static func sha256Hex(_ data: Data) -> String {
    if #available(iOS 13.0, *) {
      return cryptoKitHex(data)
    }
    return commonCryptoHex(data)
  }

  @available(iOS 13.0, *)
  private static func cryptoKitHex(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  private static func commonCryptoHex(_ data: Data) -> String {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { raw in
      _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &hash)
    }
    return hex(hash)
  }

  private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    var hex = String()
    hex.reserveCapacity(64)
    for byte in bytes {
      hex.append(String(format: "%02x", byte))
    }
    return hex
  }
}
