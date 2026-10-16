import Foundation

/// A message timestamp: the engine's `at` object.
struct HostTime: Equatable {
  let monoUs: Int64
  let wallUs: Int64

  var json: String {
    "{\"monoUs\":\(monoUs),\"wallUs\":\(wallUs)}"
  }
}

/// The host clock every message and timer uses (stateful-engine.md section 5).
protocol HostClock {
  func now() -> HostTime
}

/// `monoUs` is `ProcessInfo.systemUptime` in microseconds: the mach uptime
/// clock that `UIEvent.timestamp` and `DispatchTime(uptimeNanoseconds:)` use.
/// `wallUs` is UTC epoch microseconds.
struct SystemHostClock: HostClock {
  func now() -> HostTime {
    let uptime = ProcessInfo.processInfo.systemUptime
    let wall = Date().timeIntervalSince1970
    return HostTime(monoUs: SystemHostClock.microseconds(uptime), wallUs: SystemHostClock.microseconds(wall))
  }

  /// Converts a `TimeInterval` (for example `UIEvent.timestamp`) to whole
  /// microseconds, rounding down.
  static func microseconds(_ seconds: TimeInterval) -> Int64 {
    let micros = (seconds * 1_000_000).rounded(.down)
    guard micros.isFinite, micros > 0 else { return 0 }
    return micros >= Double(Int64.max) ? Int64.max : Int64(micros)
  }
}
