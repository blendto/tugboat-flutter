import Foundation

/// Device Farm launch inputs from process environment and launch arguments.
///
/// Environment keys win when both are present. Values stay raw strings; see
/// `TugboatLaunchParsers` for `1` / `true` / `yes` normalization (Dart parity).
enum TugboatLaunchArguments {
  static let keys: [(mapKey: String, argument: String, envKey: String)] = [
    ("emitSceneInventory", "--tugboat-emit-scene-inventory", "TUGBOAT_EMIT_SCENE_INVENTORY"),
    ("acceptActionContext", "--tugboat-accept-action-context", "TUGBOAT_ACCEPT_ACTION_CONTEXT"),
    ("collectorBaseUrl", "--tugboat-collector-base-url", "TUGBOAT_COLLECTOR_BASE_URL"),
    ("automationRunId", "--tugboat-automation-run-id", "TUGBOAT_AUTOMATION_RUN_ID"),
  ]

  static func parse(environment: [String: String], arguments: [String]) -> [String: String] {
    var values = parseArguments(arguments)
    for (mapKey, _, envKey) in keys {
      if let value = environment[envKey] {
        values[mapKey] = value
      }
    }
    return values
  }

  static func parseArguments(_ arguments: [String]) -> [String: String] {
    var values: [String: String] = [:]
    for argument in arguments {
      for (mapKey, flag, _) in keys {
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

enum TugboatLaunchParsers {
  static func parseBool(_ value: String?) -> Bool {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "1" || normalized == "true" || normalized == "yes"
  }
}

struct LaunchOptions {
  let emitSceneInventory: Bool
  let acceptActionContext: Bool
  let automationRunId: String?

  var captureRequested: Bool { emitSceneInventory || acceptActionContext }

  static func fromProcessInfo(_ info: ProcessInfo = .processInfo) -> LaunchOptions? {
    let raw = TugboatLaunchArguments.parse(environment: info.environment, arguments: info.arguments)
    let runId = raw["automationRunId"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let options = LaunchOptions(
      emitSceneInventory: TugboatLaunchParsers.parseBool(raw["emitSceneInventory"]),
      acceptActionContext: TugboatLaunchParsers.parseBool(raw["acceptActionContext"]),
      automationRunId: runId?.isEmpty == true ? nil : runId
    )
    return options.captureRequested ? options : nil
  }

  func launchLine(sessionWallUs: Int64) -> String {
    var parts = [
      "\"captureRequested\":true",
      "\"emitSceneInventory\":\(emitSceneInventory)",
      "\"acceptActionContext\":\(acceptActionContext)",
    ]
    if let automationRunId {
      parts.append("\"automationRunId\":\(JSONText.quoted(automationRunId))")
    }
    parts.append("\"captureSessionId\":\"session-\(sessionWallUs)\"")
    return "TUGBOAT_LAUNCH {" + parts.joined(separator: ",") + "}"
  }

  static func healthLine(lifecycle: String, sessionWallUs: Int64) -> String {
    if lifecycle == "dormant" {
      return "TUGBOAT_HEALTH {\"lifecycle\":\(JSONText.quoted(lifecycle))}"
    }
    return "TUGBOAT_HEALTH {\"lifecycle\":\(JSONText.quoted(lifecycle)),\"captureSessionId\":\"session-\(sessionWallUs)\"}"
  }
}
