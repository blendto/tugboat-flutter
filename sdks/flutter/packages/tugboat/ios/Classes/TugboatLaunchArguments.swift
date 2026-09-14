// Pure launch-argument parser for the `tugboat/launch` channel.
//
// This file has no Apple, Flutter, or runtime imports on purpose: it compiles
// under any Swift SDK so the parsing logic stays verifiable in isolation.
//
// iOS automation hosts (agent-device `--launch-args`, Appium/XCUITest) pass
// launch arguments far more reliably than process environment, so the same
// four capture inputs are accepted from both sources. The process environment
// wins when both are present (see `TugboatPlugin`). Everything stays a raw
// string here — Dart-side `TugboatLaunchParsers` owns all normalization. A
// bare flag with no "=" yields "true", which Dart parses as enabled.
struct TugboatLaunchArguments {
  /// Method-channel map key by launch-argument spelling, 1:1 with the
  /// `TUGBOAT_*` process-environment keys.
  static let keys: [(mapKey: String, argument: String)] = [
    ("emitSceneInventory", "--tugboat-emit-scene-inventory"),
    ("acceptActionContext", "--tugboat-accept-action-context"),
    ("collectorBaseUrl", "--tugboat-collector-base-url"),
    ("automationRunId", "--tugboat-automation-run-id"),
  ]

  /// Parses raw `mapKey → value` pairs from process arguments.
  ///
  /// A bare flag with no "=" yields "true". A flag with "=" yields the raw
  /// suffix verbatim (empty included; Dart trims blanks to null). Later
  /// occurrences win. Unknown arguments are ignored. Matching is exact and
  /// case-sensitive: `--tugboat-emit-scene-inventoryfoo` does not match.
  static func parse(_ arguments: [String]) -> [String: String] {
    var values: [String: String] = [:]
    for argument in arguments {
      for (mapKey, flag) in keys {
        if argument == flag {
          values[mapKey] = "true"
        } else if argument.hasPrefix(flag + "=") {
          values[mapKey] = String(argument.dropFirst(flag.count + 1))
        }
      }
    }
    return values
  }
}
