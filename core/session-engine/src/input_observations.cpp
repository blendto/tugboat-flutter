#include "input_observations.h"

#include <utility>

#include "capture_seam.h"
#include "engine_state.h"
#include "navigation_view.h"
#include "recorder.h"
#include "route_barrier.h"

namespace tugboat {
namespace engine {

namespace {

ObservationBoundary boundary_of(const PendingObservation& pending) {
  ObservationBoundary boundary;
  boundary.session_id = pending.session_id;
  boundary.at_ms = pending.event.at_ms;
  return boundary;
}

// Dart `_recordInputObservation`: needs a live session in the foreground.
void observe(Turn& turn, const char* type, Value data) {
  EngineState& state = *turn.state;
  if (state.lifecycle != LifecycleState::kActive) return;
  Event event = make_event(&state, *turn.session, type, turn.at.mono_us);
  event.stream = EventStream::kEvidence;
  event.data = std::move(data);
  const std::string id = event.id;
  state.interactions.observations.pending.put(
      id, PendingObservation{std::move(event), turn.session->id()});
  // Dart `_requestCapture(trigger: manual)`: the configured settle delay,
  // no forced fresh paint.
  CaptureAsk ask;
  ask.trigger = FrameTrigger::kManual;
  ask.settle_delay_ms = state.config.interaction.settle_delay_ms;
  state.captures.request(turn, {CaptureOwner::Kind::kObservation, id}, ask);
}

// Dart `_frameObservedAfter` for the latest frame.
OptString latest_observed_after(const Turn& turn,
                                const PendingObservation& pending) {
  const CaptureSeam& captures = turn.state->captures;
  const FrameProvenance* latest = captures.latest(turn.session->id());
  return captures.observed_after(
      latest == nullptr ? std::nullopt : OptString(latest->frame_id),
      boundary_of(pending));
}

// Dart `_publishInputObservation`: once, and only into its own session.
void publish(EngineState* state, Session& session, const std::string& event_id,
             const OptString& after_frame, Output* out) {
  InputObservations& observations = state->interactions.observations;
  PendingObservation* pending = observations.pending.find(event_id);
  if (pending == nullptr) return;
  PendingObservation observation = std::move(*pending);
  observations.pending.erase(event_id);
  if (observation.session_id != session.id()) return;
  observation.event.after_frame = after_frame;
  record_event(state, session, std::move(observation.event), true, out);
}

}  // namespace

void record_focus(EngineState* state, Session* session, const At& at,
                  FocusKind kind, Output* out) {
  InputObservations& observations = state->interactions.observations;
  const FocusKind previous = observations.focus;
  observations.focus = kind;
  if (kind != FocusKind::kTextInput && previous != FocusKind::kTextInput) {
    return;
  }
  if (!state->config.capabilities.focus_changes || session == nullptr) return;
  Value data = Value::object();
  data.set("focus", Value::string(focus_kind_name(kind)));
  data.set("previousFocus", Value::string(focus_kind_name(previous)));
  Turn turn{state, session, at, out};
  observe(turn, "focus_changed", std::move(data));
}

void record_system_input(Turn& turn, SystemInput input) {
  if (!turn.state->config.capabilities.system_input) return;
  Value data = Value::object();
  data.set("input", Value::string(system_input_name(input)));
  observe(turn, "system_input", std::move(data));
}

void finish_observation(Turn& turn, const std::string& event_id,
                        const CaptureResolution& resolution) {
  EngineState& state = *turn.state;
  const PendingObservation* pending =
      state.interactions.observations.pending.find(event_id);
  if (pending == nullptr) return;
  // Dart `_observeFrameAfterInput`: the frame the capture produced or
  // reused; else the active route capture's frame when it was observed
  // after the input (a system back's navigation suppresses standalone
  // captures while it runs); else the latest frame when it was.
  if (resolution.frame_id) {
    publish(&state, *turn.session, event_id, resolution.frame_id, turn.out);
    return;
  }
  if (const RouteWorkPtr route = latest_route_capture(state)) {
    await_route_barrier(&state, route,
                        {BarrierWaiter::Kind::kObservation, event_id,
                         std::nullopt});
    return;
  }
  publish(&state, *turn.session, event_id,
          latest_observed_after(turn, *pending), turn.out);
}

void observation_route_barrier_done(Turn& turn, const std::string& event_id,
                                    const RouteWork& barrier) {
  EngineState& state = *turn.state;
  const PendingObservation* pending =
      state.interactions.observations.pending.find(event_id);
  if (pending == nullptr) return;
  OptString frame = state.captures.observed_after(barrier.result->frame_id,
                                                  boundary_of(*pending));
  if (!frame) frame = latest_observed_after(turn, *pending);
  publish(&state, *turn.session, event_id, frame, turn.out);
}

void flush_observations(EngineState* state, Output* out) {
  InputObservations& observations = state->interactions.observations;
  Session* session = state->live_session();
  if (session == nullptr) {
    observations.pending.clear();
    return;
  }
  for (const std::string& id : observations.pending.keys()) {
    publish(state, *session, id, std::nullopt, out);
  }
}

}  // namespace engine
}  // namespace tugboat
