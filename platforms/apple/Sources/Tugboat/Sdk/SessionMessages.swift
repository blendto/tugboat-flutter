import Foundation

/// Types and inputs of the session, lifecycle, and identity messages the SDK
/// sends (core/session-engine/README.md, stateful messages).
enum SessionMessages {
  static let engineConfigure = "engine.configure"
  static let sessionStart = "session.start"
  static let sessionEnd = "session.end"
  static let appLifecycle = "app.lifecycle"
  static let identitySet = "identity.set"
  static let traitsSet = "traits.set"

  /// `viewport` is the key window's size in points when known, else the
  /// screen's.
  static func sessionStartInput(viewport: (width: Double, height: Double), host: HostMetadata, sessionEpoch: Int) -> String {
    var size = JSONObject()
    size.set("width", .double(viewport.width))
    size.set("height", .double(viewport.height))
    var out = JSONObject()
    out.set("viewport", size)
    out.set("platform", HostMetadata.platform)
    out.set("sessionEpoch", Int64(sessionEpoch))
    out.set("locale", host.sessionLocaleJSON)
    return out.json
  }

  static func sessionEndInput() -> String {
    "{\"reason\":\"session_end\"}"
  }

  /// `state`: `paused`, `hidden`, `inactive`, `resumed`, or `detached`.
  static func appLifecycleInput(_ state: String) -> String {
    "{\"state\":" + JSONText.quoted(state) + "}"
  }

  static func identityInput(_ userId: String?) -> String {
    "{\"userId\":" + (userId.map(JSONText.quoted) ?? "null") + "}"
  }

  /// The `traits.set` input, or nil (logged by the caller) when `traits`
  /// holds a value JSON cannot carry (NaN, infinities, non-JSON types).
  static func traitsInput(_ traits: [String: Any]) -> String? {
    let wrapped: [String: Any] = ["traits": traits]
    guard JSONSerialization.isValidJSONObject(wrapped),
      let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys])
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}
