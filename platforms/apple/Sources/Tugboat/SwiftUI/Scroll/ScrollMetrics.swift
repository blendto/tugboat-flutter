/// Engine `scroll.axis` values (Dart `Axis`).
enum ScrollAxis: String {
  case vertical
  case horizontal
}

/// One scroll position along one axis, in points: `offset` is 0 at the
/// resting start of the content, `maxExtent` the largest resting offset.
struct ScrollMetrics: Equatable {
  let axis: ScrollAxis
  let offset: Double
  let maxExtent: Double
}
