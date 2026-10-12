import Foundation
import os.log

/// The host's only log sink. Messages are public: callers never pass the API
/// key, frame bytes, or response bodies other than engine error documents.
enum HostLog {
  private static let log = OSLog(subsystem: "com.gettugboat.sdk", category: "engine")

  static func warning(_ message: String) {
    os_log("%{public}@", log: log, type: .default, message as NSString)
  }

  static func error(_ message: String) {
    os_log("%{public}@", log: log, type: .error, message as NSString)
  }
}
