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
  static let localeSet = "locale.set"

  /// `viewport` is the key window's size in points when known, else the
  /// screen's. `activationRequestId` and `explorationRunId` are sent only
  /// when non-blank (`normalizedSessionId`).
  static func sessionStartInput(
    viewport: (width: Double, height: Double), host: HostMetadata, sessionEpoch: Int,
    activationRequestId: String? = nil, explorationRunId: String? = nil
  ) -> String {
    var size = JSONObject()
    size.set("width", .double(viewport.width))
    size.set("height", .double(viewport.height))
    var out = JSONObject()
    out.set("viewport", size)
    out.set("platform", HostMetadata.platform)
    out.set("sessionEpoch", Int64(sessionEpoch))
    out.set("locale", host.sessionLocaleJSON)
    if let id = normalizedSessionId(activationRequestId) { out.set("activationRequestId", id) }
    if let id = normalizedSessionId(explorationRunId) { out.set("explorationRunId", id) }
    return out.json
  }

  /// `locale.set`: the same locale object as `session.start.locale`.
  static func localeSetInput(_ locale: LocaleSnapshot) -> String {
    var out = JSONObject()
    out.set("locale", HostMetadata.localeJSON(locale))
    return out.json
  }

  /// `id` unchanged, or nil when nil or blank: a blank id is omitted from
  /// the wire, as on Android (Flutter sends `""` verbatim).
  static func normalizedSessionId(_ id: String?) -> String? {
    guard let id = id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return id
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
