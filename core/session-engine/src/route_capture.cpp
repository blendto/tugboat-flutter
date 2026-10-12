#include "route_capture.h"

#include <memory>
#include <utility>
#include <vector>

#include "coordination.h"
#include "engine_state.h"
#include "interaction_claims.h"
#include "route_barrier.h"

namespace tugboat {
namespace engine {

namespace {

std::string epoch_key(const RouteWork& work) {
  return std::to_string(work.epoch);
}

std::string deadline_timer(const RouteWork& work) {
  return kRouteDeadlinePrefix + epoch_key(work);
}

std::string timeout_timer(const RouteWork& work) {
  return kRouteTimeoutPrefix + epoch_key(work);
}

// The active work with `epoch`, or nullptr.
RouteWorkPtr active_work(const EngineState& state, const std::string& epoch) {
  for (const auto& entry : state.navigation.routes.active.entries()) {
    if (epoch_key(*entry.second) == epoch) return entry.second;
  }
  return nullptr;
}

// Dart `_isActiveRouteCapture`.
bool is_active(const EngineState& state, const RouteWork& work) {
  const RouteWorkPtr* current =
      state.navigation.routes.active.find(work.navigator_key());
  return current != nullptr && current->get() == &work && !work.done();
}

// Removes `work` from the active map when it is still its navigator's
// work; the most recent remaining work becomes the latest. Returns whether
// it was removed.
bool deactivate(RouteCaptures* routes, const RouteWork& work) {
  const std::string& key = work.navigator_key();
  const RouteWorkPtr* current = routes->active.find(key);
  if (current == nullptr || current->get() != &work) return false;
  routes->active.erase(key);
  if (routes->latest_key && *routes->latest_key == key) {
    routes->latest_key =
        routes->active.empty()
            ? OptString()
            : OptString(routes->active.entries().back().first);
  }
  return true;
}

// The barrier is done exactly once: its timers stop, its waiters resume,
// and the publication queue it held runs on.
void complete(EngineState* state, Output* out, const RouteWorkPtr& work,
              RouteResult result) {
  if (work->done()) return;
  state->timers.cancel(deadline_timer(*work), out);
  state->timers.cancel(timeout_timer(*work), out);
  work->result = std::move(result);
  release_barrier_waiters(state, work);
  if (state->coordination.finalizing == work) release_route_finalize(state);
}

// Dart `_RouteCaptureWork.cancel`: stops its capture and completes it as
// cancelled.
void cancel_work(EngineState* state, const At& at, Output* out,
                 const RouteWorkPtr& work, CancelReason reason) {
  if (work->done()) return;
  if (work->stage == RouteStage::kCapturing && work->capture_request_id) {
    state->captures.cancel(state, at, out, *work->capture_request_id, reason);
  }
  complete(state, out, work, RouteResult{RouteOutcome::kCancelled, {},
                                              {}, work->capture_request_id});
}

// Dart `_replacePriorRouteCapture`.
void supersede(Turn& turn, const RouteWorkPtr& prior) {
  EngineState* state = turn.state;
  CaptureSeam& captures = state->captures;
  if (prior == nullptr) {
    if (state->navigation.routes.active.empty()) captures.advance_generation();
    return;
  }
  deactivate(&state->navigation.routes, *prior);
  cancel_work(state, turn.at, turn.out, prior, CancelReason::kSupersededRoute);
  // Design section 9.3 #4: every waiting capture goes, tap and scroll
  // captures included.
  captures.cancel_all(state, turn.at, turn.out, CancelReason::kSupersededRoute);
  captures.advance_generation();
}

// Dart `_updateRouteCaptureCausality`.
void link_cause(RouteCaptures* routes, const RouteWorkPtr& prior,
                const RouteWorkPtr& work) {
  const std::string* previous =
      prior == nullptr ? nullptr : prior->change.cause_event_id();
  const std::string* cause = work->change.cause_event_id();
  if (previous != nullptr && (cause == nullptr || *previous != *cause)) {
    routes->causal.erase(*previous);
    routes->superseded_interactions.insert(*previous);
  }
  if (cause != nullptr) routes->causal[*cause] = work;
}

// Dart `_attachCauseInteractionEvidence` then `_emitRouteChange`.
std::string record(Turn& turn, const RouteWork& work,
                   const OptString& after_frame,
                   const RouteChangeCapture& capture) {
  const std::string event_id = turn.state->ids.next("event");
  if (const std::string* cause = work.change.cause_event_id()) {
    attach_route_frame(turn.state, *cause, after_frame);
  }
  record_route_change(turn, event_id, work.change, after_frame, capture);
  return event_id;
}

}  // namespace

void start_route_capture(Turn& turn, VisibleRouteChange change) {
  EngineState* state = turn.state;
  NavigationState& navigation = state->navigation;
  RouteCaptures& routes = navigation.routes;
  apply_visible_route(change, &navigation.visible);
  const std::string key = change.navigator_id;
  const RouteWorkPtr* found = routes.active.find(key);
  const RouteWorkPtr prior = found == nullptr ? nullptr : *found;
  supersede(turn, prior);

  auto work = std::make_shared<RouteWork>();
  work->epoch = ++navigation.route_epoch;
  work->deadline_ms =
      change.transition_ms + state->config.interaction.settle_delay_ms;
  work->change = std::move(change);
  routes.active.put(key, work);
  routes.latest_key = key;
  if (prior != nullptr) prior->superseded_by = work;
  link_cause(&routes, prior, work);
  // Change C11: only this navigator's captures wait out its transition.
  if (work->change.transition_ms > 0) {
    routes.transitioning.insert(key);
  } else {
    routes.transitioning.erase(key);
  }
  const NavigationConfig& config = state->config.navigation;
  state->timers.schedule(
      timeout_timer(*work),
      turn.at.mono_us +
          (work->deadline_ms + config.route_barrier_timeout_ms) * 1000,
      turn.out);
  // Step 5: wake the claimed tap only now that its barrier is registered.
  if (const std::string* cause = work->change.cause_event_id()) {
    wake_claimed_tap(state, *cause, turn.at, turn.out);
  }
  if (work->deadline_ms <= 0) {
    work->stage = RouteStage::kQueued;
    enqueue_publication(turn.state, RouteFinalizePublication{work});
  } else {
    state->timers.schedule(deadline_timer(*work),
                           turn.at.mono_us + work->deadline_ms * 1000,
                           turn.out);
  }
}

void route_deadline_reached(Turn& turn, const std::string& epoch) {
  const RouteWorkPtr work = active_work(*turn.state, epoch);
  if (work == nullptr || work->stage != RouteStage::kTransitioning) return;
  turn.state->navigation.routes.transitioning.erase(work->navigator_key());
  work->stage = RouteStage::kQueued;
  enqueue_publication(turn.state, RouteFinalizePublication{work});
}

void begin_route_finalize(Turn& turn, const RouteWorkPtr& work) {
  EngineState* state = turn.state;
  if (!is_active(*state, *work)) return;
  apply_visible_route(work->change, &state->navigation.visible);
  work->stage = RouteStage::kCapturing;
  state->coordination.finalizing = work;
  CaptureAsk ask;
  ask.trigger = FrameTrigger::kRoute;
  // The deadline already waited out the settle delay.
  ask.force = true;
  work->capture_request_id = state->captures.request(
      turn, {CaptureOwner::Kind::kRoute, epoch_key(*work)}, ask);
}

void finish_route_capture(Turn& turn, const std::string& epoch,
                          const CaptureResolution& resolution) {
  EngineState* state = turn.state;
  const RouteWorkPtr work = state->coordination.finalizing;
  if (work == nullptr || epoch_key(*work) != epoch || work->done()) return;
  RouteResult result;
  result.capture_request_id = resolution.request_id;
  result.frame_id = resolution.frame_id;
  result.outcome = resolution.frame_id ? RouteOutcome::kCaptured
                                       : RouteOutcome::kFailed;
  if (is_active(*state, *work)) {
    RouteChangeCapture capture;
    capture.request_id = resolution.request_id;
    if (!resolution.frame_id) {
      capture.outcome = RouteOutcome::kFailed;
      capture.failure = std::string(capture_outcome_name(resolution.outcome));
    }
    result.event_id = record(turn, *work, resolution.frame_id, capture);
  }
  RouteCaptures& routes = state->navigation.routes;
  if (deactivate(&routes, *work)) {
    routes.transitioning.erase(work->navigator_key());
  }
  complete(state, turn.out, work, std::move(result));
}

void route_barrier_timed_out(Turn& turn, const std::string& epoch) {
  EngineState* state = turn.state;
  const RouteWorkPtr work = active_work(*state, epoch);
  if (work == nullptr || work->done()) return;
  if (work->stage == RouteStage::kCapturing && work->capture_request_id) {
    state->captures.cancel(state, turn.at, turn.out, *work->capture_request_id,
                           CancelReason::kRouteTimeout);
  }
  state->captures.advance_generation();
  RouteCaptures& routes = state->navigation.routes;
  deactivate(&routes, *work);
  routes.transitioning.erase(work->navigator_key());
  RouteChangeCapture capture;
  capture.outcome = RouteOutcome::kTimedOut;
  RouteResult result;
  result.outcome = RouteOutcome::kTimedOut;
  result.event_id = record(turn, *work, std::nullopt, capture);
  complete(state, turn.out, work, std::move(result));
}

void cancel_route_captures(EngineState* state, const At& at, Output* out,
                           CancelReason reason) {
  RouteCaptures& routes = state->navigation.routes;
  std::vector<RouteWorkPtr> active;
  for (const auto& entry : routes.active.entries()) {
    active.push_back(entry.second);
  }
  routes.active.clear();
  routes.latest_key.reset();
  routes.causal.clear();
  routes.superseded_interactions.clear();
  routes.transitioning.clear();
  clear_publications(state);
  if (active.empty()) return;
  state->captures.advance_generation();
  for (const RouteWorkPtr& work : active) {
    cancel_work(state, at, out, work, reason);
  }
}

}  // namespace engine
}  // namespace tugboat
