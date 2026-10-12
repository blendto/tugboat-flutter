#include "interaction_transaction.h"

namespace tugboat {
namespace engine {

void Transaction::mark_swipe() {
  if (is_pan_or_zoom(gesture)) return;
  gesture = Gesture::kSwipe;
  discard_pre_tap_evidence();
}

void Transaction::mark_cluster(Gesture cluster_gesture, double cluster_scale,
                               int64_t cluster_pointer_count) {
  if (!is_pan_or_zoom(cluster_gesture) && cluster_gesture != Gesture::kSwipe) {
    return;
  }
  gesture = cluster_gesture;
  scale = cluster_scale;
  pointer_count = cluster_pointer_count;
  discard_pre_tap_evidence();
}

void Transaction::discard_pre_tap_evidence() {
  pre_tap_evidence.reset();
  failure_reason.reset();
}

}  // namespace engine
}  // namespace tugboat
