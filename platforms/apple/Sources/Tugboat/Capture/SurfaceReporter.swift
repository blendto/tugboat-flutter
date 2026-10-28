/// The engine's `surface {boundaryRect, generation}` fact
/// (stateful-engine.md 8.2): the capture boundary in window points and the
/// boundary transform generation, which advances whenever the rect changes
/// (rotation, split view, Stage Manager resize). The first rect keeps
/// generation 0, the generation the engine's first (`initial`) capture
/// request already carries, so that capture is not made stale by the first
/// report. Main thread only.
final class SurfaceReporter {
  static let factType = "surface"

  private let post: (_ inputJSON: String) -> Void
  private var last: BoundaryRect?
  private var generation: Int64 = 0

  init(post: @escaping (_ inputJSON: String) -> Void) {
    self.post = post
  }

  /// Posts a `surface` fact when `rect` differs from the last one reported.
  func observe(_ rect: BoundaryRect) {
    guard rect != last else { return }
    if last != nil {
      generation += 1
    }
    last = rect
    var input = JSONObject()
    input.set("boundaryRect", rect.json)
    input.set("generation", generation)
    post(input.json)
  }
}
