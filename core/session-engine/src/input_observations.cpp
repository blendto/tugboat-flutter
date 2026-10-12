#include "input_observations.h"

#include <utility>

#include "engine_state.h"
#include "interaction_claims.h"
#include "recorder.h"

namespace tugboat {
namespace engine {

namespace {

// Dart `_recordInputObservation`: needs a live session in the foreground.
void observe(InteractionTurn& turn, const char* type, Value data) {
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
  ask.not_before_mono_us =
      turn.at.mono_us + state.config.interaction.settle_delay_ms * 1000;
  ask.context = current_capture_context(state);
  state.captures.issue({CaptureOwner::Kind::kObservation, id},
                                    ask, &state.ids, turn.out);
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
  InteractionTurn turn{state, session, at, out};
  observe(turn, "focus_changed", std::move(data));
}

void record_system_input(InteractionTurn& turn, SystemInput input) {
  if (!turn.state->config.capabilities.system_input) return;
  Value data = Value::object();
  data.set("input", Value::string(system_input_name(input)));
  observe(turn, "system_input", std::move(data));
}

void finish_observation(InteractionTurn& turn, const std::string& event_id,
                        const CaptureResolution& resolution) {
  EngineState& state = *turn.state;
  const PendingObservation* pending =
      state.interactions.observations.pending.find(event_id);
  if (pending == nullptr) return;
  // Dart `_observeFrameAfterInput`: the frame the capture produced or
  // reused, else the latest frame when it completed after the input.
  // (Phase 3d checks an active route barrier in between.)
  OptString frame = resolution.frame_id;
  if (!frame) {
    const FrameProvenance* latest = state.captures.latest(turn.session->id());
    ObservationBoundary boundary;
    boundary.session_id = pending->session_id;
    boundary.at_ms = pending->event.at_ms;
    frame = state.captures.observed_after(
        latest == nullptr ? std::nullopt : OptString(latest->frame_id),
        boundary);
  }
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
