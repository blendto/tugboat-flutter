// How asynchronous Dart work runs in a synchronous engine
// (docs/stateful-engine.md section 8):
//
// - Deferred work (Dart microtasks). A capture answer or a route barrier
//   resumes its waiter only after the step that produced it has finished,
//   so the waiter sees the state that step leaves (for example the route
//   that superseded its capture). The engine runs deferred work, in order,
//   after every command (`run_deferred`).
// - The publication queue (Dart `_queue`, design section 9.3 #3). Route
//   finalization and the publication of settled taps and completed
//   gestures run one at a time, in order; a route finalize holds the queue
//   until its route is done. A degraded tap observation (no frame)
//   publishes at once instead.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_COORDINATION_H
#define TUGBOAT_SESSION_ENGINE_COORDINATION_H

#include <deque>
#include <string>
#include <variant>

#include "capture_types.h"
#include "output.h"
#include "route_work.h"
#include "turn.h"

namespace tugboat {
namespace engine {

struct EngineState;

// A logical capture request resolved.
struct CaptureAnswer {
  CaptureOwner owner;
  CaptureResolution resolution;
};

// A route barrier `waiter` waits on is done; `work` is the barrier.
struct BarrierResume {
  BarrierWaiter waiter;
  RouteWorkPtr work;
};

// The publication queue may run on.
struct PublicationsResume {};

using DeferredTask =
    std::variant<CaptureAnswer, BarrierResume, PublicationsResume>;

// One entry of the publication queue.
struct RouteFinalizePublication {
  RouteWorkPtr work;
};
struct TapPublication {
  std::string interaction_id;
};
struct GesturePublication {
  std::string interaction_id;
};
using Publication =
    std::variant<RouteFinalizePublication, TapPublication, GesturePublication>;

struct Coordination {
  std::deque<DeferredTask> deferred;
  std::deque<Publication> publications;
  // The route finalize holding the publication queue, if any.
  RouteWorkPtr finalizing;
};

// Queues deferred work.
void defer(EngineState* state, DeferredTask task);

// Runs deferred work until none is left. Without a live session it is
// dropped: its waiters belonged to a session that has ended. A waiter that
// no longer exists (torn down, or of a replaced session) ignores its task.
void run_deferred(const At& at, EngineState* state, Output* out);

// Appends a publication. The queue runs as deferred work (Dart chains each
// task on `_queue`), unless a route finalize holds it.
void enqueue_publication(EngineState* state, Publication publication);

// The route finalize holding the queue is over (its route is done): the
// queue runs on once the work that finished it has settled.
void release_route_finalize(EngineState* state);

// Teardown: forgets queued publications. Their owners are being torn down,
// and each publishes or drops its own work.
void clear_publications(EngineState* state);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_COORDINATION_H
