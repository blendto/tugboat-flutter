#include "coordination.h"

#include <utility>

#include "engine_state.h"
#include "input_observations.h"
#include "interaction_publish.h"
#include "route_barrier.h"
#include "route_capture.h"
#include "scroll_interactions.h"
#include "tap_settle.h"

namespace tugboat {
namespace engine {

namespace {

void answer(Turn& turn, const CaptureAnswer& task) {
  const std::string& key = task.owner.key;
  const CaptureResolution& resolution = task.resolution;
  switch (task.owner.kind) {
    case CaptureOwner::Kind::kTapSettle:
      finish_tap_settle(turn, key, resolution);
      break;
    case CaptureOwner::Kind::kGesture:
      finish_gesture(turn, key, resolution);
      break;
    case CaptureOwner::Kind::kScrollEnd:
      finish_scroll_end(turn, key, resolution);
      break;
    case CaptureOwner::Kind::kObservation:
      finish_observation(turn, key, resolution);
      break;
    case CaptureOwner::Kind::kRoute:
      finish_route_capture(turn, key, resolution);
      break;
    case CaptureOwner::Kind::kNone:
      break;
  }
}

void resume(Turn& turn, const BarrierResume& task) {
  const RouteWorkPtr barrier = settle_barrier_resume(turn.state, task);
  if (barrier == nullptr) return;
  const BarrierWaiter& waiter = task.waiter;
  switch (waiter.kind) {
    case BarrierWaiter::Kind::kTapRoute:
    case BarrierWaiter::Kind::kTapSuccessor:
      tap_route_barrier_done(turn, waiter, *barrier);
      break;
    case BarrierWaiter::Kind::kGestureWalk:
      gesture_route_barrier_done(turn, waiter.key, *barrier);
      break;
    case BarrierWaiter::Kind::kScrollWalk:
      scroll_route_barrier_done(turn, waiter.key, *barrier);
      break;
    case BarrierWaiter::Kind::kObservation:
      observation_route_barrier_done(turn, waiter.key, *barrier);
      break;
  }
}

// Runs one publication. Returns whether it now holds the queue.
bool run(Turn& turn, const Publication& publication) {
  if (const auto* route = std::get_if<RouteFinalizePublication>(&publication)) {
    return begin_route_finalize(turn, route->work);
  }
  if (const auto* tap = std::get_if<TapPublication>(&publication)) {
    publish_settled_tap(turn, tap->interaction_id);
  } else {
    publish_completed_gesture(
        turn, std::get<GesturePublication>(publication).interaction_id);
  }
  return false;
}

void run_publications(Turn& turn) {
  Coordination& coordination = turn.state->coordination;
  while (coordination.finalizing == nullptr &&
         !coordination.publications.empty()) {
    const Publication next = std::move(coordination.publications.front());
    coordination.publications.pop_front();
    run(turn, next);
  }
}

}  // namespace

void defer(EngineState* state, DeferredTask task) {
  state->coordination.deferred.push_back(std::move(task));
}

void run_deferred(const At& at, EngineState* state, Output* out) {
  std::deque<DeferredTask>& deferred = state->coordination.deferred;
  while (!deferred.empty()) {
    Session* session = state->live_session();
    if (session == nullptr) {
      deferred.clear();
      return;
    }
    const DeferredTask task = std::move(deferred.front());
    deferred.pop_front();
    Turn turn{state, session, at, out};
    if (const auto* capture = std::get_if<CaptureAnswer>(&task)) {
      answer(turn, *capture);
    } else if (const auto* barrier = std::get_if<BarrierResume>(&task)) {
      resume(turn, *barrier);
    } else {
      run_publications(turn);
    }
  }
}

void enqueue_publication(EngineState* state, Publication publication) {
  state->coordination.publications.push_back(std::move(publication));
  if (state->coordination.finalizing == nullptr) {
    defer(state, PublicationsResume{});
  }
}

void release_route_finalize(EngineState* state) {
  state->coordination.finalizing = nullptr;
  defer(state, PublicationsResume{});
}

void clear_publications(EngineState* state) {
  state->coordination.publications.clear();
  state->coordination.finalizing = nullptr;
}

}  // namespace engine
}  // namespace tugboat
