// Value types shared by the interaction module (docs/stateful-engine.md
// section 9): surface points and the closed gesture vocabulary.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_TYPES_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_TYPES_H

#include <cmath>

namespace tugboat {
namespace engine {

// A point in the adapter's surface space, in logical pixels (Dart `Offset`).
struct Point {
  double x = 0;
  double y = 0;

  Point operator+(const Point& other) const {
    return {x + other.x, y + other.y};
  }
  Point operator-(const Point& other) const {
    return {x - other.x, y - other.y};
  }
  Point operator/(double divisor) const { return {x / divisor, y / divisor}; }
  bool operator==(const Point& other) const {
    return x == other.x && y == other.y;
  }
  bool operator!=(const Point& other) const { return !(*this == other); }
  // Dart `Offset.distance`.
  double distance() const { return std::sqrt(x * x + y * y); }
};

// Dart `InteractionGesture`. The collector accepts exactly these wire names.
enum class Gesture {
  kTap,
  kSwipe,
  kScroll,
  kPan,
  kZoomIn,
  kZoomOut,
  kCancelled,
};

// `tap`, `swipe`, `scroll`, `pan`, `zoom_in`, `zoom_out`, `cancelled`.
inline const char* gesture_name(Gesture gesture) {
  switch (gesture) {
    case Gesture::kTap: return "tap";
    case Gesture::kSwipe: return "swipe";
    case Gesture::kScroll: return "scroll";
    case Gesture::kPan: return "pan";
    case Gesture::kZoomIn: return "zoom_in";
    case Gesture::kZoomOut: return "zoom_out";
    case Gesture::kCancelled: return "cancelled";
  }
  return "cancelled";
}

inline bool is_pan_or_zoom(Gesture gesture) {
  return gesture == Gesture::kPan || gesture == Gesture::kZoomIn ||
         gesture == Gesture::kZoomOut;
}

inline bool is_zoom(Gesture gesture) {
  return gesture == Gesture::kZoomIn || gesture == Gesture::kZoomOut;
}

// Dart `skipsTapSettlement`: the gesture completes with its own capture
// instead of the tap-settle state machine, and abandonment keeps it.
inline bool skips_tap_settlement(Gesture gesture) {
  return gesture == Gesture::kSwipe || gesture == Gesture::kScroll ||
         is_pan_or_zoom(gesture);
}

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_TYPES_H
