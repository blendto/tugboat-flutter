import CryptoKit
import Foundation

enum ContentHash {
  static func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    var hex = String()
    hex.reserveCapacity(64)
    for byte in digest {
      hex.append(String(format: "%02x", byte))
    }
    return hex
  }
}
