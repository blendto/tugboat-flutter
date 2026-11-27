/// Engine `scroll.phase` values.
enum ScrollPhase: String {
  case start
  case update
  case end
  case overscroll
}

/// Builds `scroll {scrollableId, phase, offset?, axis?, maxScrollExtent?,
/// anchor?}` facts (stateful-engine.md 9.1). `overscroll` carries only the
/// id; `anchor` only `start`.
enum ScrollFacts {
  static func fact(
    id: String,
    phase: ScrollPhase,
    metrics: ScrollMetrics,
    at: HostTime,
    anchor: TargetAnchor? = nil
  ) -> AdapterFact {
    var input = JSONObject()
    input.set("scrollableId", id)
    input.set("phase", phase.rawValue)
    if phase != .overscroll {
      input.set("offset", metrics.offset)
      input.set("axis", metrics.axis.rawValue)
      input.set("maxScrollExtent", metrics.maxExtent)
      if phase == .start, let anchor = anchor {
        input.set("anchor", anchor.json)
      }
    }
    return AdapterFact(type: FactTypes.scroll, input: input, at: at)
  }
}
