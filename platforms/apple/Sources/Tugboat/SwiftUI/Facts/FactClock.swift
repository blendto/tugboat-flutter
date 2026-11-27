import Foundation

/// Fact times for the adapter. `UITouch.timestamp` is seconds of
/// `systemUptime`, the host's `monoUs` clock (`SystemHostClock`), so a touch
/// keeps its own time; other facts use the clock now.
struct FactClock {
  let clock: HostClock

  func now() -> HostTime {
    clock.now()
  }

  /// The time of an event stamped `uptime` seconds (`UITouch.timestamp`),
  /// with `wallUs` back-dated by the same amount.
  func at(uptime: TimeInterval) -> HostTime {
    let monoUs = SystemHostClock.microseconds(uptime)
    let now = clock.now()
    let (age, overflow) = now.monoUs.subtractingReportingOverflow(monoUs)
    let (wallUs, wallOverflow) = now.wallUs.subtractingReportingOverflow(overflow ? 0 : age)
    return HostTime(monoUs: monoUs, wallUs: wallOverflow ? now.wallUs : wallUs)
  }
}
