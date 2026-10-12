// One navigation's route-capture work (Dart `_RouteCaptureWork`) and the
// barrier other work waits on, as plain data. The transitions live in
// route_capture.cpp; waiting on a barrier in route_barrier.cpp.
//
//   transitioning ──deadline──► queued ──publish queue──► capturing
//        │      (no deadline: queued at once)                 │ capture
//        │                                                     ▼ resolved
//        ├── superseded on its navigator, or torn down ──► done (cancelled)
//        ├── barrier timeout (transition + settle + 5 s) ──► done (timed out)
//        └─────────────────────────────────────────────► done (captured |
//                                                              failed)
//
// A work is done exactly once. Work superseded on its navigator links its
// successor (`superseded_by`), which barrier waiters may follow.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ROUTE_WORK_H
#define TUGBOAT_SESSION_ENGINE_ROUTE_WORK_H

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "models.h"
#include "route_change.h"

namespace tugboat {
namespace engine {

// Who waits on a route barrier (Dart `_awaitRouteCaptureBarrier` callers).
// `key` is the interaction id, scroll start id, or event id of the waiter.
// With `expected_cause`, the wait follows a cancelled barrier only to a
// successor claimed by that same interaction.
struct BarrierWaiter {
  enum class Kind {
    kTapRoute,       // a tap waiting for the route it caused
    kTapSuccessor,   // a tap observing a later route instead
    kGestureWalk,    // a swipe, pan, or zoom's after-capture fallback
    kScrollWalk,     // a scroll's after-capture fallback
    kObservation,    // a focus or system-input observation
  };
  Kind kind = Kind::kTapRoute;
  std::string key;
  OptString expected_cause;
};

enum class RouteStage { kTransitioning, kQueued, kCapturing, kDone };

// Dart `_RouteCaptureOutcome`.
enum class RouteOutcome { kCaptured, kFailed, kCancelled, kTimedOut };

// Dart `_RouteCaptureResult`: the barrier's terminal outcome.
struct RouteResult {
  RouteOutcome outcome = RouteOutcome::kCancelled;
  OptString frame_id;
  OptString event_id;            // the `route_change` it recorded
  OptString capture_request_id;  // its capture's `capture_request-N`
};

struct RouteWork {
  int64_t epoch = 0;
  VisibleRouteChange change;
  // Transition plus settle delay: when the route capture is requested.
  int64_t deadline_ms = 0;
  RouteStage stage = RouteStage::kTransitioning;
  std::optional<RouteResult> result;  // once done
  std::shared_ptr<RouteWork> superseded_by;
  // The route capture's logical request while capturing.
  OptString capture_request_id;
  // Waiters to resume when the barrier is done.
  std::vector<BarrierWaiter> waiters;

  bool done() const { return result.has_value(); }
  // The navigator whose work this is (Dart `_routeCaptureKey`).
  const std::string& navigator_key() const { return change.navigator_id; }
};

using RouteWorkPtr = std::shared_ptr<RouteWork>;

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_ROUTE_WORK_H
