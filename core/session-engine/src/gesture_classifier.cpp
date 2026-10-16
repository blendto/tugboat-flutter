#include "gesture_classifier.h"

#include <cmath>

namespace tugboat {
namespace engine {

bool exceeds_touch_slop(const GestureConfig& config, Point down,
                        Point current) {
  return (current - down).distance() >= config.touch_slop;
}

std::optional<Gesture> classify_cluster(const GestureConfig& config,
                                        const ClusterSample& sample) {
  if (sample.pointer_count >= 2 && sample.start_span > 0) {
    const double span_delta =
        std::fabs(sample.current_span - sample.start_span);
    if (span_delta >= config.scale_slop) {
      return sample.current_span > sample.start_span ? Gesture::kZoomIn
                                                     : Gesture::kZoomOut;
    }
  }
  if ((sample.current_centroid - sample.start_centroid).distance() >=
      config.pan_slop) {
    return sample.pointer_count >= 3 ? Gesture::kSwipe : Gesture::kPan;
  }
  return std::nullopt;
}

std::optional<Gesture> classify_trackpad(const GestureConfig& config,
                                         double scale, Point pan) {
  if (scale >= config.trackpad_scale_threshold) {
    return Gesture::kZoomIn;
  }
  if (scale > 0 && scale <= 1 / config.trackpad_scale_threshold) {
    return Gesture::kZoomOut;
  }
  if (pan.distance() >= config.pan_slop) {
    return Gesture::kPan;
  }
  return std::nullopt;
}

Point centroid_of(const std::vector<Point>& points) {
  double x = 0;
  double y = 0;
  for (const Point& point : points) {
    x += point.x;
    y += point.y;
  }
  const double count = static_cast<double>(points.size());
  return {x / count, y / count};
}

double max_span(const std::vector<Point>& points) {
  double span = 0;
  for (size_t i = 0; i < points.size(); ++i) {
    for (size_t j = i + 1; j < points.size(); ++j) {
      const double distance = (points[i] - points[j]).distance();
      if (distance > span) span = distance;
    }
  }
  return span;
}

}  // namespace engine
}  // namespace tugboat
