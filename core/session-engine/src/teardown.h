// Ordered teardown of in-flight work when the app deactivates, a session
// ends, or a session is replaced (docs/stateful-engine.md section 4.2,
// subtlety 9.3.5). The order is Dart's and is fixed here; the work each stage
// tears down belongs to later phases (3c interactions, 3d navigation and
// capture), which register their handlers on this extension point. Phase 3a
// owns no in-flight work, so no stage has a handler yet.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_TEARDOWN_H
#define TUGBOAT_SESSION_ENGINE_TEARDOWN_H

#include <array>
#include <cstddef>
#include <functional>
#include <vector>

#include "output.h"

namespace tugboat {
namespace engine {

enum class TeardownStage {
  kTapSettles,             // cancel pending tap settles
  kRouteCaptures,          // cancel route-capture work
  kCaptureWork,            // invalidate scheduled and in-flight captures
  kPendingPointers,        // abandon pending pointers
  kReleasedTransactions,   // clear released interaction transactions
  kGestureAndScroll,       // finalize gesture and scroll interactions
  kInputObservations,      // flush deferred focus / system-input events
};

constexpr size_t kTeardownStageCount = 7;

// Why work is torn down. Handlers use it as the cancellation or rejection
// reason (Dart: `lifecycle_deactivate`, `session_end`, `dispose`,
// `session_replacement`).
enum class TeardownCause {
  kLifecycle,
  kSessionEnd,
  kDispose,
  kSessionReplacement,
};

// Dart's order for `paused` / `hidden` / `detached` and for session end.
constexpr std::array<TeardownStage, kTeardownStageCount> kDeactivationOrder = {
    TeardownStage::kTapSettles,       TeardownStage::kRouteCaptures,
    TeardownStage::kCaptureWork,      TeardownStage::kPendingPointers,
    TeardownStage::kReleasedTransactions, TeardownStage::kGestureAndScroll,
    TeardownStage::kInputObservations,
};

// Dart's order in `start()`: gestures and scrolls finalize before pending
// pointers are abandoned.
constexpr std::array<TeardownStage, kTeardownStageCount> kReplacementOrder = {
    TeardownStage::kTapSettles,       TeardownStage::kRouteCaptures,
    TeardownStage::kCaptureWork,      TeardownStage::kGestureAndScroll,
    TeardownStage::kPendingPointers,  TeardownStage::kReleasedTransactions,
    TeardownStage::kInputObservations,
};

const std::array<TeardownStage, kTeardownStageCount>& teardown_order(
    TeardownCause cause);

class Teardown {
 public:
  using Handler = std::function<void(TeardownCause, Output*)>;

  // Extension point: a later phase registers the work it owns per stage.
  void on(TeardownStage stage, Handler handler);

  // Runs every registered handler, stage by stage in `cause`'s order.
  void run(TeardownCause cause, Output* out) const;

 private:
  std::array<std::vector<Handler>, kTeardownStageCount> handlers_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_TEARDOWN_H
