import Foundation

/// The SwiftUI adapter's failure log. Adapter code is written so that no
/// host-app value can reach a trapping operation (no force unwraps, checked
/// conversions, bounded walks); what it cannot read it skips, masks, or
/// reports as a failure reason. This records each such site once, so a
/// failure on every frame cannot flood the log.
enum AdapterLog {
  private static let logged = Locked(Set<String>())

  /// Logs `message` the first time `site` reports; later reports are dropped.
  static func once(_ site: String, _ message: @autoclosure () -> String) {
    let first = logged.withLock { $0.insert(site).inserted }
    guard first else { return }
    HostLog.warning("SwiftUI adapter \(site): \(message()); further reports here are not logged")
  }
}
