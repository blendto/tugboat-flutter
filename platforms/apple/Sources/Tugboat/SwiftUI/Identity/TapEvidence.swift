/// `tap {anchor | failureReason}` evidence for a pointer-up
/// (stateful-engine.md 9.1).
enum TapEvidence: Equatable {
  case anchor(TargetAnchor)
  case failed(FailureReason)

  /// The engine's closed `TapFailureReason` names the adapter uses.
  enum FailureReason: String {
    case noTargetAtPoint = "no_target_at_point"
    case noActionableCandidate = "no_actionable_candidate"
    case resolutionError = "resolution_error"
  }

  var json: JSONObject {
    var out = JSONObject()
    switch self {
    case let .anchor(anchor): out.set("anchor", anchor.json)
    case let .failed(reason): out.set("failureReason", reason.rawValue)
    }
    return out
  }
}
