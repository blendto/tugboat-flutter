import Foundation

/// What one session's configuration gives the outbox: the input of the
/// salted app identity (never stored), the bounds, and the SDK version.
struct OutboxContext {
  let identityInput: Data
  let bounds: OutboxBounds
  let sdkVersion: String

  init(identityInput: Data, bounds: OutboxBounds, sdkVersion: String) {
    self.identityInput = identityInput
    self.bounds = bounds
    self.sdkVersion = sdkVersion
  }

  /// `collectorBaseURL ‖ appId ‖ apiKey`, newline-separated.
  init(host: HostConfig, bounds: OutboxBounds) {
    self.init(
      identityInput: Data("\(host.collectorBaseURL)\n\(host.appId)\n\(host.apiKey)".utf8), bounds: bounds,
      sdkVersion: host.sdkVersion)
  }
}

/// The units one `http.send` wrote, with the attempt number each got; the
/// answer deletes a unit's entry only if this is still its latest attempt.
struct OutboxAttempt: Equatable {
  struct Unit: Equatable {
    let key: String
    let number: Int
  }

  let units: [Unit]

  var headerValue: String {
    units.map { $0.key }.joined(separator: ",")
  }
}

/// The counts one drain pass logs (W11 design section 3.3).
struct OutboxPassCounts: Equatable {
  var replayed = 0
  var expired = 0
  var evicted = 0
  var corrupt = 0
  var identityMismatch = 0

  var isEmpty: Bool {
    self == OutboxPassCounts()
  }

  func line(bytesOnDisk: Int) -> String {
    "outbox pass replayed=\(replayed) expired=\(expired) evicted=\(evicted) corrupt=\(corrupt) "
      + "identityMismatch=\(identityMismatch) bytesOnDisk=\(bytesOnDisk)"
  }
}

/// The drainer's wait after a retried replay: 2 s doubling per attempt up to
/// 5 min, and at least the collector's `Retry-After` (delta-seconds or an
/// HTTP-date), itself capped at 5 min.
enum OutboxBackoff {
  static let baseMs = 2_000
  static let maxMs = 300_000

  static func delayMs(attempts: Int, retryAfter: String?, nowWallMs: Int64) -> Int {
    let exponent = min(max(attempts, 1), 16) - 1
    let curve = min(maxMs, baseMs << exponent)
    guard let retryAfter = retryAfter, let asked = retryAfterMs(retryAfter, nowWallMs: nowWallMs) else { return curve }
    return max(curve, asked)
  }

  /// A `Retry-After` value in milliseconds, capped at `maxMs`; nil when it
  /// is neither delta-seconds nor an IMF-fixdate.
  static func retryAfterMs(_ raw: String, nowWallMs: Int64) -> Int? {
    guard let value = CollectorResponse.forwardRetryAfter(raw) else { return nil }
    if value.allSatisfy({ $0.isASCII && $0.isNumber }) {
      guard let seconds = Int(value) else { return maxMs }
      return seconds > maxMs / 1000 ? maxMs : seconds * 1000
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    guard let date = formatter.date(from: value) else { return nil }
    let delta = Int64(date.timeIntervalSince1970 * 1000) - nowWallMs
    return Int(min(Int64(maxMs), max(0, delta)))
  }
}
