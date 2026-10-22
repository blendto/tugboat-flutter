import Foundation

/// Turns a collector response into the `transport.result` outcome the engine
/// accepts. The engine rejects a `body` over 64 KiB or a `status` outside
/// 100–599 as `invalid_message`, and a rejected answer leaves its request
/// unanswered, which stalls every delivery lane. So neither may reach it.
enum CollectorResponse {
  /// `transport.result.body` carries at most this many UTF-8 bytes.
  static let maxBodyBytes = 64 * 1024

  /// `transport.result.retryAfter` carries at most this many bytes.
  static let maxRetryAfterBytes = 128

  static let validStatuses = 100...599

  static func forwardRetryAfter(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespaces)
    guard let trimmed, !trimmed.isEmpty, trimmed.utf8.count <= maxRetryAfterBytes else {
      return nil
    }
    return trimmed
  }

  /// `.http` for a status the engine accepts, otherwise `.error`.
  static func outcome(status: Int, body: Data, retryAfter: String? = nil) -> TransportOutcome {
    guard validStatuses.contains(status) else {
      HostLog.warning("collector answered with status \(status); reporting a transport error")
      return .error
    }
    return .http(
      status: status, body: text(body), retryAfter: forwardRetryAfter(retryAfter))
  }

  /// The body as text of at most `maxBodyBytes` UTF-8 bytes. The bytes are
  /// cut back to a complete character before decoding, and invalid bytes,
  /// which decode to U+FFFD and so can grow, are trimmed after.
  static func text(_ body: Data) -> String {
    let decoded = String(decoding: completePrefix(body), as: UTF8.self)
    guard decoded.utf8.count > maxBodyBytes else { return decoded }
    var trimmed = String.UnicodeScalarView()
    var size = 0
    for scalar in decoded.unicodeScalars {
      let scalarSize = UTF8.width(scalar)
      guard size + scalarSize <= maxBodyBytes else { break }
      trimmed.append(scalar)
      size += scalarSize
    }
    return String(trimmed)
  }

  /// At most `maxBodyBytes` bytes of `body`, without a trailing partial
  /// UTF-8 sequence.
  static func completePrefix(_ body: Data) -> Data {
    let bytes = [UInt8](body.prefix(maxBodyBytes))
    var lead = bytes.count - 1
    // A sequence is at most 4 bytes: look back over up to 3 continuation bytes.
    while lead >= 0, lead > bytes.count - 4, bytes[lead] & 0xC0 == 0x80 {
      lead -= 1
    }
    guard lead >= 0, lead + sequenceLength(lead: bytes[lead]) > bytes.count else {
      return Data(bytes)
    }
    return Data(bytes[0..<lead])
  }

  /// Length announced by a lead byte; 1 for ASCII and for invalid leads.
  private static func sequenceLength(lead: UInt8) -> Int {
    switch lead {
    case 0xF0...0xF7: return 4
    case 0xE0...0xEF: return 3
    case 0xC0...0xDF: return 2
    default: return 1
    }
  }
}
