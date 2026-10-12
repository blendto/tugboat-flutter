/// Gesture thresholds in **points**, the unit of every coordinate the
/// adapter sends (`x`, `y`, scroll offsets). The engine compares positions
/// against its `gesture` config, so the host must configure the engine with
/// `engineJSON` of the same instance the adapter uses for its local
/// tap-evidence check; then both agree on what is a tap.
///
/// UIKit publishes no slop constants (stateful-engine.md section 6: "iOS uses
/// UIKit recognizer defaults"), so these are the values UIKit's recognizers
/// behave with: a pan and a scroll view begin after about 10 pt of travel
/// (`touchSlop`); paging and pinch need about twice that (`panSlop`,
/// `scaleSlop`). Flutter's trackpad scale threshold (1.08) is kept.
struct GestureConfig: Equatable {
  static let uiKitDefault = GestureConfig(touchSlop: 10, panSlop: 20, scaleSlop: 20, trackpadScaleThreshold: 1.08)

  let touchSlop: Double
  let panSlop: Double
  let scaleSlop: Double
  let trackpadScaleThreshold: Double

  /// The engine's `engine.configure.gesture` group.
  var engineJSON: JSONObject {
    var out = JSONObject()
    out.set("touchSlop", touchSlop)
    out.set("panSlop", panSlop)
    out.set("scaleSlop", scaleSlop)
    out.set("trackpadScaleThreshold", trackpadScaleThreshold)
    return out
  }
}
