#include "tap_settle.h"

#include <optional>

#include "capture_seam.h"
#include "coordination.h"
#include "engine_state.h"
#include "interaction_publish.h"
#include "navigation_view.h"
#include "route_barrier.h"

namespace tugboat {
namespace engine {

namespace {

// What a settled tap observed (Dart `_TapSettleObservation`, reduced to
// what publication reads).
struct TapObservation {
  OptString after_frame;
  // No frame and no captured route: Dart publishes it at once instead of
  // through the serialized publication queue.
  bool degraded = false;
};

// Dart `_ensureReconciliationSweepScheduled`: one sweep timer, armed for the
// earliest deadline plus the fact grace.
void ensure_sweep(Turn& turn) {
  EngineState& state = *turn.state;
  if (state.timers.armed(kSweepTimerId)) return;
  const std::optional<int64_t> earliest =
      state.interactions.registry.earliest_claim_deadline();
  if (!earliest) return;
  const int64_t grace_ms = state.config.interaction.fact_grace_ms;
  state.timers.schedule(kSweepTimerId, turn.mono_at_ms(*earliest + grace_ms),
                        turn.out);
}

std::string timer_id(const std::string& interaction_id) {
  return kSettleTimerPrefix + interaction_id;
}

OptString temporal(const Turn& turn, const Transaction& tx,
                   const OptString& frame_id) {
  return temporal_after_frame(turn.state->captures, tx, *turn.session,
                              frame_id);
}

OptString latest_frame(const Turn& turn) {
  const FrameProvenance* latest =
      turn.state->captures.latest(turn.session->id());
  return latest == nullptr ? std::nullopt : OptString(latest->frame_id);
}

// Dart `_writeTapSettleObservation`.
void write(Turn& turn, const std::string& interaction_id,
           const OptString& after_frame) {
  EngineState& state = *turn.state;
  TapSettles& settles = state.interactions.settles;
  const TapSettle* settle = settles.find(interaction_id);
  if (settle == nullptr) return;
  const TransactionPtr tx = settle->tx;
  settles.erase(interaction_id);
  clear_causal_route_state(&state, interaction_id);
  tx->gesture = Gesture::kTap;
  tx->after_frame = after_frame;
  publish_interaction(&state, *turn.session, *tx, turn.out);
}

// Dart `_publishTapSettleObservation`: a degraded observation publishes at
// once; others wait behind the publication queue (design section 9.3 #3).
void publish(Turn& turn, TapSettle& settle,
             const TapObservation& observation) {
  if (observation.degraded) {
    write(turn, settle.tx->id(), observation.after_frame);
    return;
  }
  settle.phase = SettlePhase::kPublishing;
  settle.after_frame = observation.after_frame;
  enqueue_publication(turn.state, TapPublication{settle.tx->id()});
}

// Dart `_frameMatchesTapOrigin`.
bool frame_matches_origin(const Turn& turn, const Transaction& tx,
                          const OptString& frame_id) {
  const FrameProvenance* frame =
      frame_id ? turn.state->captures.find(*frame_id) : nullptr;
  return frame != nullptr &&
         frame->context.route_epoch == tx.origin.route.route_epoch &&
         frame->context.route == tx.origin.route.route;
}

// Dart `_tapObservationFromRouteBarrier`: the route's frame is the
// observation when it is the frame of that route.
TapObservation from_route(const Turn& turn, const Transaction& tx,
                          const RouteWork& barrier) {
  const OptString& frame_id = barrier.result->frame_id;
  const FrameProvenance* frame =
      frame_id ? turn.state->captures.find(*frame_id) : nullptr;
  const bool valid =
      frame != nullptr &&
      frame->context.session_id == turn.session->id() &&
      frame->context.route_epoch == barrier.epoch &&
      frame->context.route == barrier.change.destination_route;
  TapObservation observation;
  observation.after_frame =
      temporal(turn, tx, valid ? frame_id : std::nullopt);
  observation.degraded = !valid && !observation.after_frame;
  return observation;
}

// Dart `_routeBarrierWasSupersededByAutomatic`.
bool superseded_by_other_cause(const Transaction& tx,
                               const RouteWork& barrier) {
  if (barrier.result->outcome != RouteOutcome::kCancelled) return false;
  const std::string* cause = barrier.change.cause_event_id();
  if (cause == nullptr || *cause != tx.id()) return false;
  const std::string* successor_cause =
      barrier.superseded_by == nullptr
          ? nullptr
          : barrier.superseded_by->change.cause_event_id();
  return successor_cause == nullptr || *successor_cause != tx.id();
}

void observe_successor(Turn& turn, TapSettle& settle,
                       const RouteWorkPtr& route, SuccessorKind kind,
                       bool causal) {
  settle.phase = SettlePhase::kSuccessorBarrier;
  settle.successor = kind;
  settle.successor_causal = causal;
  const std::string& id = settle.tx->id();
  await_route_barrier(
      turn.state, route,
      {BarrierWaiter::Kind::kTapSuccessor, id,
       causal ? OptString(id) : std::nullopt});
}

// Dart `_tapObservationForRouteCapture`.
void observe_caused_route(Turn& turn, TapSettle& settle,
                          const RouteWorkPtr& route) {
  const std::string& id = settle.tx->id();
  turn.state->navigation.routes.causal.erase(id);
  settle.phase = SettlePhase::kRouteBarrier;
  await_route_barrier(turn.state, route,
                      {BarrierWaiter::Kind::kTapRoute, id, OptString(id)});
}

// Dart `_tapObservationForStandaloneCapture`.
void request_capture(Turn& turn, TapSettle& settle) {
  EngineState& state = *turn.state;
  const Transaction& tx = *settle.tx;
  const RouteStamp now = current_route_stamp(state);
  settle.phase = SettlePhase::kCapturing;
  settle.requested_route_epoch = now.route_epoch;
  settle.requested_route = now.route;
  settle.route_changed = now.route_epoch != tx.origin.route.route_epoch ||
                         now.route != tx.origin.route.route ||
                         cause_was_superseded(state, tx.id());
  settle.capture_request_id = state.captures.request(
      turn, {CaptureOwner::Kind::kTapSettle, tx.id()},
      interaction_capture(tx.id()));
}

// After the claim window: the route this tap caused, else its own capture.
void after_claim_window(Turn& turn, TapSettle& settle) {
  RouteWorkPtr route = settle.initial_route;
  if (route == nullptr) {
    route = causal_route_capture(*turn.state, settle.tx->id());
  }
  if (route != nullptr) {
    observe_caused_route(turn, settle, route);
  } else {
    request_capture(turn, settle);
  }
}

// Dart `_waitForTapClaimWindow`: wait out the rest of the claim window,
// unless the tap is already claimed.
void enter_claim_window(Turn& turn, TapSettle& settle) {
  EngineState& state = *turn.state;
  const InteractionConfig& config = state.config.interaction;
  const Transaction& tx = *settle.tx;
  if (config.claim_window_ms > 0 && !tx.claimed && tx.claim_deadline_ms) {
    const int64_t wait_until_ms = *tx.claim_deadline_ms + config.fact_grace_ms;
    if (turn.now_ms() < wait_until_ms) {
      settle.phase = SettlePhase::kClaimWindow;
      state.timers.schedule(timer_id(tx.id()), turn.mono_at_ms(wait_until_ms),
                            turn.out);
      return;
    }
  }
  after_claim_window(turn, settle);
}

}  // namespace

void release_for_claims(Turn& turn, const TransactionPtr& tx) {
  EngineState& state = *turn.state;
  if (!tx->released_at_ms) tx->released_at_ms = turn.now_ms();
  state.interactions.registry.release(tx);
  // A zero window (Dart's microtask-only rollback mode) closes at release.
  tx->claim_deadline_ms =
      *tx->released_at_ms + state.config.interaction.claim_window_ms;
  ensure_sweep(turn);
}

void sweep_released(Turn& turn) {
  EngineState& state = *turn.state;
  const InteractionConfig& config = state.config.interaction;
  state.interactions.registry.sweep(turn.now_ms(), config.fact_grace_ms,
                                    config.max_released);
  if (state.interactions.registry.has_released()) ensure_sweep(turn);
}

void clear_released(EngineState* state, Output* out) {
  state->timers.cancel(kSweepTimerId, out);
  Session* session = state->live_session();
  for (const TransactionPtr& tx :
       state->interactions.registry.take_all_released()) {
    if (session != nullptr) finalize_abandoned(state, *session, *tx, out);
  }
}

void start_tap_settle(Turn& turn, const TransactionPtr& tx) {
  EngineState& state = *turn.state;
  TapSettles& settles = state.interactions.settles;
  TapSettle started;
  started.tx = tx;
  // Dart `_initialTapRouteCapture`: the route active at pointer-up, when
  // this tap caused it.
  const RouteWorkPtr active = latest_route_capture(state);
  const std::string* cause =
      active == nullptr ? nullptr : active->change.cause_event_id();
  if (cause != nullptr && *cause == tx->id()) started.initial_route = active;
  settles.put(tx->id(), std::move(started));
  TapSettle& settle = *settles.find(tx->id());
  const int64_t delay_ms = state.config.interaction.settle_delay_ms;
  if (settle.initial_route == nullptr && delay_ms > 0) {
    state.timers.schedule(timer_id(tx->id()),
                          turn.at.mono_us + delay_ms * 1000, turn.out);
    return;
  }
  enter_claim_window(turn, settle);
}

void advance_tap_settle(Turn& turn, const std::string& interaction_id) {
  TapSettle* settle = turn.state->interactions.settles.find(interaction_id);
  if (settle == nullptr) return;
  if (settle->phase == SettlePhase::kSettleDelay) {
    enter_claim_window(turn, *settle);
  } else if (settle->phase == SettlePhase::kClaimWindow) {
    after_claim_window(turn, *settle);
  }
}

void wake_tap_settle(Turn& turn, const std::string& interaction_id) {
  TapSettle* settle = turn.state->interactions.settles.find(interaction_id);
  if (settle == nullptr || settle->phase != SettlePhase::kClaimWindow) return;
  turn.state->timers.cancel(timer_id(interaction_id), turn.out);
  after_claim_window(turn, *settle);
}

void finish_tap_settle(Turn& turn, const std::string& interaction_id,
                       const CaptureResolution& resolution) {
  TapSettle* settle = turn.state->interactions.settles.find(interaction_id);
  if (settle == nullptr || settle->phase != SettlePhase::kCapturing) return;
  settle->capture_request_id.reset();
  const Transaction& tx = *settle->tx;
  const bool matches = frame_matches_origin(turn, tx, resolution.frame_id);
  // Dart `_standaloneCaptureHasReplacementRoute`.
  const RouteWorkPtr replacement = latest_route_capture(*turn.state);
  if (!matches && replacement != nullptr &&
      replacement->epoch != settle->requested_route_epoch) {
    const std::string* cause = replacement->change.cause_event_id();
    const bool causal = cause != nullptr && *cause == tx.id();
    observe_successor(turn, *settle, replacement, SuccessorKind::kReplacement,
                      causal);
    return;
  }
  // Dart `_standaloneTapSameRouteObservation`.
  const bool captured = matches && !settle->route_changed;
  TapObservation observation;
  observation.after_frame = captured
                                ? resolution.frame_id
                                : temporal(turn, tx, latest_frame(turn));
  observation.degraded = !captured && !observation.after_frame;
  publish(turn, *settle, observation);
}

void tap_route_barrier_done(Turn& turn, const BarrierWaiter& waiter,
                            const RouteWork& barrier) {
  TapSettle* settle = turn.state->interactions.settles.find(waiter.key);
  if (settle == nullptr) return;
  const Transaction& tx = *settle->tx;
  if (waiter.kind == BarrierWaiter::Kind::kTapRoute &&
      settle->phase == SettlePhase::kRouteBarrier) {
    if (!superseded_by_other_cause(tx, barrier)) {
      publish(turn, *settle, from_route(turn, tx, barrier));
    } else if (barrier.superseded_by != nullptr) {
      observe_successor(turn, *settle, barrier.superseded_by,
                        SuccessorKind::kAutomatic, false);
    } else {
      publish(turn, *settle, TapObservation{std::nullopt, true});
    }
    return;
  }
  if (waiter.kind != BarrierWaiter::Kind::kTapSuccessor ||
      settle->phase != SettlePhase::kSuccessorBarrier) {
    return;
  }
  // Dart `_supersededRouteTapObservation` / `_successorTapObservation`:
  // a later route is only a temporal observation.
  const OptString frame =
      settle->successor == SuccessorKind::kAutomatic
          ? barrier.result->frame_id
          : from_route(turn, tx, barrier).after_frame;
  TapObservation observation;
  observation.after_frame = temporal(turn, tx, frame);
  observation.degraded = !observation.after_frame;
  publish(turn, *settle, observation);
}

void publish_settled_tap(Turn& turn, const std::string& interaction_id) {
  const TapSettle* settle =
      turn.state->interactions.settles.find(interaction_id);
  if (settle == nullptr || settle->phase != SettlePhase::kPublishing) return;
  write(turn, interaction_id, settle->after_frame);
}

void cancel_tap_settles(EngineState* state, const At& at, Output* out,
                        TeardownCause cause) {
  TapSettles& settles = state->interactions.settles;
  for (const auto& entry : settles.entries()) {
    state->timers.cancel(timer_id(entry.first), out);
  }
  TapSettles cancelled = std::move(settles);
  settles.clear();
  for (const auto& entry : cancelled.entries()) {
    if (entry.second.capture_request_id) {
      state->captures.cancel(state, at, out, *entry.second.capture_request_id,
                             teardown_cancel_reason(cause));
    }
  }
}

}  // namespace engine
}  // namespace tugboat
