// Contact tracking and gesture recognition over raw pointer facts (Dart
// `InputCapture`): which contacts are down, the multi-pointer cluster, and
// the trackpad pan/zoom contact. It turns each fact into the controller
// signals Dart's `InputCapture` calls (`recordPointerDown`,
// `markPendingTapAsSwipe`, …) and never touches engine state, so it can be
// tested on its own. Thresholds come from `GestureConfig` per call.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_POINTER_TRACKER_H
#define TUGBOAT_SESSION_ENGINE_POINTER_TRACKER_H

#include <cstdint>
#include <map>
#include <optional>
#include <variant>
#include <vector>

#include "config.h"
#include "interaction_types.h"
#include "tap_evidence.h"

namespace tugboat {
namespace engine {

struct PointerDownSignal {
  int64_t pointer = 0;
  Point position;
  std::optional<TapEvidence> tap;
};

struct MarkSwipeSignal {
  int64_t pointer = 0;
};

struct MarkClusterSignal {
  int64_t pointer = 0;
  Gesture gesture = Gesture::kPan;
  double scale = 1;
  int64_t pointer_count = 2;
};

// A secondary pointer joined another pointer's cluster gesture.
struct SuppressSignal {
  int64_t pointer = 0;
};

struct PointerUpSignal {
  int64_t pointer = 0;
  Point position;
  std::optional<TapEvidence> tap;
};

struct PointerCancelSignal {
  int64_t pointer = 0;
  Point position;
};

using PointerSignal =
    std::variant<PointerDownSignal, MarkSwipeSignal, MarkClusterSignal,
                 SuppressSignal, PointerUpSignal, PointerCancelSignal>;

using PointerSignals = std::vector<PointerSignal>;

class PointerTracker {
 public:
  void down(int64_t pointer, Point position, std::optional<TapEvidence> tap,
            PointerSignals* out);
  void move(const GestureConfig& config, int64_t pointer, Point position,
            PointerSignals* out);
  void up(const GestureConfig& config, int64_t pointer, Point position,
          std::optional<TapEvidence> tap, PointerSignals* out);
  void cancel(int64_t pointer, Point position, PointerSignals* out);

  void pan_zoom_start(int64_t pointer, Point position, PointerSignals* out);
  void pan_zoom_update(const GestureConfig& config, int64_t pointer,
                       Point position, Point pan, double scale,
                       PointerSignals* out);
  void pan_zoom_end(int64_t pointer, Point position, PointerSignals* out);

  // Forgets every contact (Dart `InputCapture.reset`).
  void reset();

 private:
  // Dart `_MultiPointerSession`.
  struct Cluster {
    int64_t primary = 0;
    std::vector<int64_t> pointers;  // insertion-ordered set
    double initial_span = 0;
    Point end_position;
    Point start_centroid;
    double start_span = 0;
    std::optional<Gesture> classified;
    int64_t classified_count = 1;
    double scale = 1;
    double base_scale = 1;

    bool has(int64_t pointer) const;
    void remove(int64_t pointer);
  };

  // The trackpad pan/zoom contact.
  struct PanZoom {
    int64_t pointer = 0;
    std::optional<Gesture> classified;
    Point end_position;
  };

  bool tracking(int64_t pointer) const { return down_.count(pointer) != 0; }
  bool cluster_has(int64_t pointer) const;
  bool points_of(const std::vector<int64_t>& pointers,
                 std::vector<Point>* out) const;
  void classify_swipe(const GestureConfig& config, int64_t pointer,
                      Point position, PointerSignals* out);
  void ensure_cluster();
  void grow_cluster(int64_t pointer, PointerSignals* out);
  void update_travel(int64_t pointer, Point position, Point previous);
  void refresh_baseline();
  void classify_cluster_now(const GestureConfig& config, PointerSignals* out);
  void apply_classification(PointerSignals* out);
  void complete_cluster(PointerSignals* out);
  void forget(int64_t pointer);

  std::map<int64_t, Point> down_;
  std::map<int64_t, Point> positions_;
  std::vector<int64_t> order_;
  std::map<int64_t, bool> swiped_;
  std::optional<Cluster> cluster_;
  std::optional<PanZoom> pan_zoom_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_POINTER_TRACKER_H
