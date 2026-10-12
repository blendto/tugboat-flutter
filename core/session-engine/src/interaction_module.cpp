// Interactions (docs/stateful-engine.md section 9): the `input.pointer`,
// `input.panZoom`, `scroll`, `focus`, and `systemInput` messages, the
// `interaction.` timers, and the interaction teardown stages. Its state is
// `EngineState::interactions` (interaction_state.h); it asks for frames
// through the capture seam (`EngineState::captures`), whose answers reach
// it as deferred work (coordination.h).
#include <string>

#include "engine_state.h"
#include "fact_command.h"
#include "input_observations.h"
#include "interaction_facts.h"
#include "interaction_publish.h"
#include "modules.h"
#include "pointer_interactions.h"
#include "scroll_interactions.h"
#include "tap_settle.h"

namespace tugboat {
namespace engine {

namespace {

Turn live_turn(EngineState* state, const At& at, Output* out) {
  return Turn{state, state->live_session(), at, out};
}

// ------------------------------------------------------------- messages

void apply_pointer(const ModuleRegistry&, EngineState* state,
                   const PointerFact& fact, const At& at, Output* out) {
  PointerTracker& tracker = state->interactions.pointers;
  const GestureConfig& config = state->config.gesture;
  PointerSignals signals;
  switch (fact.phase) {
    case PointerPhase::kDown:
      tracker.down(fact.pointer_id, fact.position, fact.tap, &signals);
      break;
    case PointerPhase::kMove:
      tracker.move(config, fact.pointer_id, fact.position, &signals);
      break;
    case PointerPhase::kUp:
      tracker.up(config, fact.pointer_id, fact.position, fact.tap, &signals);
      break;
    case PointerPhase::kCancel:
      tracker.cancel(fact.pointer_id, fact.position, &signals);
      break;
  }
  Turn turn = live_turn(state, at, out);
  apply_pointer_signals(turn, signals);
}

void apply_pan_zoom(const ModuleRegistry&, EngineState* state,
                    const PanZoomFact& fact, const At& at, Output* out) {
  PointerTracker& tracker = state->interactions.pointers;
  PointerSignals signals;
  switch (fact.phase) {
    case PanZoomPhase::kStart:
      tracker.pan_zoom_start(fact.pointer_id, fact.position, &signals);
      break;
    case PanZoomPhase::kUpdate:
      tracker.pan_zoom_update(state->config.gesture, fact.pointer_id,
                              fact.position, fact.pan, fact.scale, &signals);
      break;
    case PanZoomPhase::kEnd:
      tracker.pan_zoom_end(fact.pointer_id, fact.position, &signals);
      break;
  }
  Turn turn = live_turn(state, at, out);
  apply_pointer_signals(turn, signals);
}

void apply_scroll(const ModuleRegistry&, EngineState* state,
                  const ScrollFact& fact, const At& at, Output* out) {
  Turn turn = live_turn(state, at, out);
  record_scroll(turn, fact);
}

// `focus` applies without a session too, so the focus kind stays current.
void apply_focus(const ModuleRegistry&, EngineState* state,
                 const FocusKind& kind, const At& at, Output* out) {
  record_focus(state, state->live_session(), at, kind, out);
}

void apply_system_input(const ModuleRegistry&, EngineState* state,
                        const SystemInput& input, const At& at, Output* out) {
  Turn turn = live_turn(state, at, out);
  record_system_input(turn, input);
}

// --------------------------------------------------------------- timers

void fire_interaction_timer(const std::string& timer_id, const At& at,
                            EngineState* state, Output* out) {
  if (state->live_session() == nullptr) return;
  Turn turn = live_turn(state, at, out);
  std::string key;
  if (timer_id == kSweepTimerId) {
    sweep_released(turn);
  } else if (timer_key(timer_id, kSettleTimerPrefix, &key)) {
    advance_tap_settle(turn, key);
  } else if (timer_key(timer_id, kScrollEndTimerPrefix, &key)) {
    advance_scroll_end(turn, key);
  }
}

// ------------------------------------------------- teardown and lifecycle

void teardown_tap_settles(TeardownCause cause, const At& at,
                          EngineState* state, Output* out) {
  cancel_tap_settles(state, at, out, cause);
}

void teardown_pending_pointers(TeardownCause, const At&, EngineState* state,
                               Output* out) {
  abandon_pending_pointers(state, out);
  state->interactions.pointers.reset();
}

void teardown_released(TeardownCause, const At&, EngineState* state,
                       Output* out) {
  clear_released(state, out);
}

void teardown_gestures_and_scrolls(TeardownCause, const At&,
                                   EngineState* state, Output* out) {
  finalize_gestures(state, out);
  finalize_scroll_interactions(state, out);
  clear_scroll_state(state, out);
}

void teardown_observations(TeardownCause, const At&, EngineState* state,
                           Output* out) {
  flush_observations(state, out);
}

// Per-session interaction state starts empty (Dart `start()`).
void reset_for_session(const At&, EngineState* state, Output*) {
  InteractionState& interactions = state->interactions;
  interactions.registry.clear();
  interactions.emitted_inventories.clear();
}

}  // namespace

void register_interaction_module(ModuleRegistry* registry) {
  registry->add_command(
      "input.pointer",
      {AtRule::kMono, SessionPolicy::kEventProducing,
       decode_fact<PointerFact, decode_pointer_fact, apply_pointer>});
  registry->add_command(
      "input.panZoom",
      {AtRule::kMono, SessionPolicy::kEventProducing,
       decode_fact<PanZoomFact, decode_pan_zoom_fact, apply_pan_zoom>});
  registry->add_command(
      "scroll", {AtRule::kMono, SessionPolicy::kEventProducing,
                 decode_fact<ScrollFact, decode_scroll_fact, apply_scroll>});
  registry->add_command(
      "focus", {AtRule::kMono, SessionPolicy::kAny,
                decode_fact<FocusKind, decode_focus_fact, apply_focus>});
  registry->add_command(
      "systemInput",
      {AtRule::kMono, SessionPolicy::kEventProducing,
       decode_fact<SystemInput, decode_system_input_fact, apply_system_input>});
  registry->add_timers("interaction.", fire_interaction_timer);
  // Dart's order (design section 4.2); `teardown.h` orders the stages.
  registry->add_teardown(TeardownStage::kTapSettles, teardown_tap_settles);
  registry->add_teardown(TeardownStage::kPendingPointers,
                         teardown_pending_pointers);
  registry->add_teardown(TeardownStage::kReleasedTransactions,
                         teardown_released);
  registry->add_teardown(TeardownStage::kGestureAndScroll,
                         teardown_gestures_and_scrolls);
  registry->add_teardown(TeardownStage::kInputObservations,
                         teardown_observations);
  registry->on_session_started(reset_for_session);
  for (const char* type : {"interaction", "focus_changed", "system_input"}) {
    registry->add_engine_event_type(type);
  }
}

}  // namespace engine
}  // namespace tugboat
