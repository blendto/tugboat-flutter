#include "pointer_tracker.h"

#include <algorithm>
#include <utility>

#include "gesture_classifier.h"

namespace tugboat {
namespace engine {

bool PointerTracker::Cluster::has(int64_t pointer) const {
  return std::find(pointers.begin(), pointers.end(), pointer) !=
         pointers.end();
}

void PointerTracker::Cluster::remove(int64_t pointer) {
  pointers.erase(std::remove(pointers.begin(), pointers.end(), pointer),
                 pointers.end());
}

bool PointerTracker::cluster_has(int64_t pointer) const {
  return cluster_ && cluster_->has(pointer);
}

bool PointerTracker::points_of(const std::vector<int64_t>& pointers,
                               std::vector<Point>* out) const {
  out->clear();
  for (int64_t pointer : pointers) {
    const auto it = positions_.find(pointer);
    if (it == positions_.end()) return false;
    out->emplace_back(it->second);
  }
  return out->size() >= 2;
}

void PointerTracker::down(int64_t pointer, Point position,
                          std::optional<TapEvidence> tap,
                          PointerSignals* out) {
  down_[pointer] = position;
  positions_[pointer] = position;
  order_.push_back(pointer);
  swiped_[pointer] = false;
  out->emplace_back(PointerDownSignal{pointer, position, std::move(tap)});
  if (positions_.size() >= 2) {
    if (cluster_) {
      grow_cluster(pointer, out);
    } else {
      ensure_cluster();
    }
  }
}

void PointerTracker::move(const GestureConfig& config, int64_t pointer,
                          Point position, PointerSignals* out) {
  if (!tracking(pointer)) return;
  const Point previous = positions_[pointer];
  positions_[pointer] = position;
  if (cluster_has(pointer)) {
    update_travel(pointer, position, previous);
    classify_cluster_now(config, out);
    return;
  }
  classify_swipe(config, pointer, position, out);
}

void PointerTracker::up(const GestureConfig& config, int64_t pointer,
                        Point position, std::optional<TapEvidence> tap,
                        PointerSignals* out) {
  if (!tracking(pointer)) return;
  const Point previous = positions_[pointer];
  positions_[pointer] = position;
  if (cluster_has(pointer)) {
    update_travel(pointer, position, previous);
    if (previous != position) classify_cluster_now(config, out);
    if (cluster_->classified) {
      cluster_->remove(pointer);
      forget(pointer);
      if (cluster_->pointers.empty()) {
        complete_cluster(out);
      } else {
        // A replacement finger must join this gesture, not start its own.
        refresh_baseline();
      }
      return;
    }
    cluster_.reset();
  }
  out->emplace_back(PointerUpSignal{pointer, position, std::move(tap)});
  forget(pointer);
  ensure_cluster();
}

void PointerTracker::cancel(int64_t pointer, Point position,
                            PointerSignals* out) {
  if (cluster_has(pointer)) {
    const Cluster cluster = *cluster_;
    out->emplace_back(PointerCancelSignal{cluster.primary, position});
    for (int64_t member : cluster.pointers) {
      if (member != cluster.primary) out->emplace_back(SuppressSignal{member});
    }
    cluster_.reset();
    for (int64_t member : cluster.pointers) forget(member);
    return;
  }
  if (pan_zoom_ && pan_zoom_->pointer == pointer) pan_zoom_.reset();
  out->emplace_back(PointerCancelSignal{pointer, position});
  forget(pointer);
}

void PointerTracker::pan_zoom_start(int64_t pointer, Point position,
                                    PointerSignals* out) {
  pan_zoom_ = PanZoom{pointer, std::nullopt, position};
  out->emplace_back(PointerDownSignal{pointer, position, std::nullopt});
}

void PointerTracker::pan_zoom_update(const GestureConfig& config,
                                     int64_t pointer, Point position,
                                     Point pan, double scale,
                                     PointerSignals* out) {
  if (!pan_zoom_ || pan_zoom_->pointer != pointer) return;
  pan_zoom_->end_position = position + pan;
  const std::optional<Gesture> gesture = classify_trackpad(config, scale, pan);
  if (!gesture) return;
  pan_zoom_->classified = gesture;
  out->emplace_back(MarkClusterSignal{pointer, *gesture, scale, 2});
}

void PointerTracker::pan_zoom_end(int64_t pointer, Point position,
                                  PointerSignals* out) {
  if (!pan_zoom_ || pan_zoom_->pointer != pointer) return;
  if (pan_zoom_->classified) {
    out->emplace_back(
        PointerUpSignal{pointer, pan_zoom_->end_position, std::nullopt});
  } else {
    out->emplace_back(PointerCancelSignal{pointer, position});
  }
  pan_zoom_.reset();
  forget(pointer);
}

void PointerTracker::reset() {
  cluster_.reset();
  pan_zoom_.reset();
  down_.clear();
  positions_.clear();
  order_.clear();
  swiped_.clear();
}

void PointerTracker::classify_swipe(const GestureConfig& config,
                                    int64_t pointer, Point position,
                                    PointerSignals* out) {
  if (swiped_[pointer]) return;
  if (exceeds_touch_slop(config, down_[pointer], position)) {
    swiped_[pointer] = true;
    out->emplace_back(MarkSwipeSignal{pointer});
  }
}

void PointerTracker::ensure_cluster() {
  if (cluster_ || order_.size() < 2) return;
  std::vector<int64_t> pointers;
  for (int64_t pointer : order_) {
    if (std::find(pointers.begin(), pointers.end(), pointer) ==
        pointers.end()) {
      pointers.push_back(pointer);
    }
  }
  std::vector<Point> points;
  if (!points_of(order_, &points)) return;
  Cluster cluster;
  cluster.primary = order_.front();
  cluster.end_position = points.front();
  cluster.pointers = std::move(pointers);
  cluster.start_centroid = centroid_of(points);
  cluster.start_span = max_span(points);
  cluster.initial_span = cluster.start_span;
  cluster_ = std::move(cluster);
}

void PointerTracker::grow_cluster(int64_t pointer, PointerSignals* out) {
  if (!cluster_ || cluster_->has(pointer)) return;
  cluster_->pointers.push_back(pointer);
  if (cluster_->classified) out->emplace_back(SuppressSignal{pointer});
  refresh_baseline();
}

void PointerTracker::update_travel(int64_t pointer, Point position,
                                   Point previous) {
  Cluster& cluster = *cluster_;
  if (pointer == cluster.primary) {
    cluster.end_position = position;
  } else if (!cluster.has(cluster.primary)) {
    // Continue from the primary's last point with active-centroid travel.
    cluster.end_position =
        cluster.end_position +
        (position - previous) / static_cast<double>(cluster.pointers.size());
  }
}

void PointerTracker::refresh_baseline() {
  Cluster& cluster = *cluster_;
  // A contact change alters the span without scaling the content.
  cluster.base_scale = cluster.scale;
  std::vector<Point> points;
  if (!points_of(cluster.pointers, &points)) return;
  cluster.start_centroid = centroid_of(points);
  cluster.start_span = max_span(points);
  if (!cluster.classified) cluster.initial_span = cluster.start_span;
}

void PointerTracker::classify_cluster_now(const GestureConfig& config,
                                          PointerSignals* out) {
  if (!cluster_) return;
  Cluster& cluster = *cluster_;
  std::vector<Point> points;
  if (!points_of(cluster.pointers, &points)) return;
  const Point centroid = centroid_of(points);
  const double span = max_span(points);
  const double scale = cluster.start_span > 0
                           ? cluster.base_scale * span / cluster.start_span
                           : 1.0;
  ClusterSample sample;
  sample.pointer_count = cluster.pointers.size();
  sample.start_span = cluster.initial_span;
  sample.current_span = cluster.initial_span * scale;
  sample.start_centroid = cluster.start_centroid;
  sample.current_centroid = centroid;
  const std::optional<Gesture> gesture = classify_cluster(config, sample);
  if (!gesture) return;
  cluster.classified = gesture;
  cluster.classified_count = static_cast<int64_t>(cluster.pointers.size());
  cluster.scale = scale;
  apply_classification(out);
}

void PointerTracker::apply_classification(PointerSignals* out) {
  const Cluster& cluster = *cluster_;
  if (!cluster.classified) return;
  out->emplace_back(MarkClusterSignal{cluster.primary, *cluster.classified,
                                   cluster.scale, cluster.classified_count});
  for (int64_t member : cluster.pointers) {
    if (member != cluster.primary) out->emplace_back(SuppressSignal{member});
  }
}

void PointerTracker::complete_cluster(PointerSignals* out) {
  if (!cluster_ || !cluster_->classified) return;
  apply_classification(out);
  const Cluster cluster = *cluster_;
  out->emplace_back(
      PointerUpSignal{cluster.primary, cluster.end_position, std::nullopt});
  cluster_.reset();
  for (int64_t member : cluster.pointers) forget(member);
}

void PointerTracker::forget(int64_t pointer) {
  down_.erase(pointer);
  positions_.erase(pointer);
  const auto it = std::find(order_.begin(), order_.end(), pointer);
  if (it != order_.end()) order_.erase(it);
  swiped_.erase(pointer);
}

}  // namespace engine
}  // namespace tugboat
