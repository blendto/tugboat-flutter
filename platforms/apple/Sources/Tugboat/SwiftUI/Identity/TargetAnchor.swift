/// A resolved target, serialized as the engine's `targetAnchor`
/// (conformance/README.md) plus `toolkit: "swiftui"` (design note 6). The
/// toolkit is never a hash input. Visible text and accessibility labels are
/// never part of it.
struct TargetAnchor: Equatable {
  static let toolkit = "swiftui"

  let widgetType: String
  let role: String?
  let fingerprint: String
  let confidence: Confidence
  let tagFingerprint: String?
  let routeKey: String
  let tag: String?
  let canonicalPath: String
  let relativePosition: String?
  let enabled: Bool?
  let actions: [String]

  var json: JSONObject {
    var out = JSONObject()
    out.set("schemaVersion", IdentityHash.fingerprintSchemaVersion)
    out.set("widgetType", widgetType)
    if let role = role {
      out.set("role", role)
    }
    if !fingerprint.isEmpty {
      out.set("fingerprint", fingerprint)
      out.set("fingerprintConfidence", confidence.wire)
    }
    if let tagFingerprint = tagFingerprint {
      out.set("tagFingerprint", tagFingerprint)
    }
    out.set("fingerprintParts", fingerprintParts)
    if !canonicalPath.isEmpty {
      out.set("canonicalPath", canonicalPath)
    }
    if let relativePosition = relativePosition {
      out.set("relativePosition", relativePosition)
    }
    if let enabled = enabled {
      out.set("enabled", enabled)
    }
    if !actions.isEmpty {
      out.set("actions", .array(actions.map { .string($0) }))
    }
    out.set("toolkit", TargetAnchor.toolkit)
    return out
  }

  /// Small serialized evidence, not the hash input (the path is).
  private var fingerprintParts: JSONObject {
    var parts = JSONObject()
    parts.set("schemaVersion", String(IdentityHash.fingerprintSchemaVersion))
    parts.set("routeKey", routeKey)
    if let tag = tag {
      parts.set("tag", tag)
    }
    return parts
  }
}
