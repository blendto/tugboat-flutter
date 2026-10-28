// Pure gesture classification (Dart `input_capture.dart`): single-pointer
// touch slop, the multi-pointer cluster (span and centroid), and trackpad
// pan/zoom thresholds. Every threshold comes from the `gesture` config group,
// so each toolkit passes its own values (design sections 6 and 9.2).
// No state; not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_GESTURE_CLASSIFIER_H
#define TUGBOAT_SESSION_ENGINE_GESTURE_CLASSIFIER_H

#include <cstddef>
#include <optional>
#include <vector>

#include "config.h"
#include "interaction_types.h"

namespace tugboat {
namespace engine {

// One look at a multi-pointer touch cluster.
struct ClusterSample {
  size_t pointer_count = 0;
  double start_span = 0;
  double current_span = 0;
  Point start_centroid;
  Point current_centroid;
};

// A single pointer has travelled far enough from its down point to be a
// swipe (Dart: `delta.distance >= kTouchSlop`).
bool exceeds_touch_slop(const GestureConfig& config, Point down, Point current);

// Dart `classifyMultiPointerGesture`: zoom wins when the span changed by at
// least `scaleSlop`; otherwise shared travel of at least `panSlop` is a pan
// (two pointers) or a swipe (three or more). Nothing yet: nullopt.
std::optional<Gesture> classify_cluster(const GestureConfig& config,
                                        const ClusterSample& sample);

// Dart `classifyTrackpadPanZoom` for one pan/zoom update: a scale at least
// `trackpadScaleThreshold` (or at most its reciprocal) zooms; otherwise a
// pan of at least `panSlop` pans.
std::optional<Gesture> classify_trackpad(const GestureConfig& config,
                                         double scale, Point pan);

// The mean of `points` (Dart `_centroidOf`). `points` must not be empty.
Point centroid_of(const std::vector<Point>& points);

// The largest distance between any two of `points` (Dart `_maxSpan`).
double max_span(const std::vector<Point>& points);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_GESTURE_CLASSIFIER_H
