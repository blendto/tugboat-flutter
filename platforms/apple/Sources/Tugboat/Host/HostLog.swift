import Foundation
import os.log

/// The host's only log sink. Messages are public: callers never pass the API
/// key, frame bytes, or response bodies other than engine error documents.
enum HostLog {
  private static let log = OSLog(subsystem: "com.gettugboat.sdk", category: "engine")
  private static let launchLog = OSLog(subsystem: "com.gettugboat.sdk", category: "launch")
  private static let outboxLog = OSLog(subsystem: "com.gettugboat.sdk", category: "outbox")

  static func launch(_ message: String) {
    os_log("%{public}@", log: launchLog, type: .default, message as NSString)
  }

  /// The durable outbox: one line per drain pass, and write failures.
  static func outbox(_ message: String) {
    os_log("%{public}@", log: outboxLog, type: .default, message as NSString)
  }

  static func warning(_ message: String) {
    os_log("%{public}@", log: log, type: .default, message as NSString)
  }

  static func error(_ message: String) {
    os_log("%{public}@", log: log, type: .error, message as NSString)
  }

  /// Diagnostics (capture boundaries, surfaces); kept only while debug
  /// logging is enabled for the subsystem.
  static func debug(_ message: @autoclosure () -> String) {
    guard log.isEnabled(type: .debug) else { return }
    os_log("%{public}@", log: log, type: .debug, message() as NSString)
  }
}
