// Capture coordination (docs/stateful-engine.md section 8.2): the
// `capture.result` and `surface` facts, the `capture.due` timer, the
// capture-work teardown stage, and the captures the lifecycle asks for
// (`initial` at session start, a forced `lifecycle` capture on resume).
// Its state is the capture seam (`EngineState::captures`).
#include <string>

#include "capture_facts.h"
#include "engine_state.h"
#include "fact_command.h"
#include "modules.h"
#include "teardown.h"

namespace tugboat {
namespace engine {

namespace {

// Accepted without a session too, so a late answer's frame is released.
void apply_capture_result(const ModuleRegistry&, EngineState* state,
                          const CaptureResult& result, const At& at,
                          Output* out) {
  state->captures.on_result(state, at, out, result);
}

void apply_surface(const ModuleRegistry&, EngineState* state,
                   const SurfaceFact& fact, const At&, Output*) {
  state->captures.observe_surface(fact.boundary, fact.generation);
}

void fire_capture_timer(const std::string& timer_id, const At& at,
                        EngineState* state, Output* out) {
  if (state->live_session() == nullptr) return;
  std::string host_request_id;
  if (timer_id == kCaptureDueTimerId) {
    state->captures.on_due(state, at, out);
  } else if (timer_key(timer_id, kCaptureAnswerTimerPrefix,
                       &host_request_id)) {
    state->captures.on_answer_deadline(state, at, out, host_request_id);
  }
}

void teardown_capture_work(TeardownCause cause, const At& at,
                           EngineState* state, Output* out) {
  state->captures.invalidate(state, at, out, teardown_cancel_reason(cause));
}

void request_lifecycle_capture(FrameTrigger trigger, const At& at,
                               EngineState* state, Output* out) {
  Turn turn{state, state->live_session(), at, out};
  CaptureAsk ask;
  ask.trigger = trigger;
  ask.force = trigger == FrameTrigger::kLifecycle;
  state->captures.request(turn, {}, ask);
}

// Dart `start()`: frames are per session; then the `initial` capture.
void start_session_captures(const At& at, EngineState* state, Output* out) {
  state->captures.reset();
  request_lifecycle_capture(FrameTrigger::kInitial, at, state, out);
}

// Dart `recordAppLifecycleState(resumed)`.
void resume_captures(const At& at, EngineState* state, Output* out) {
  request_lifecycle_capture(FrameTrigger::kLifecycle, at, state, out);
}

}  // namespace

void register_capture_module(ModuleRegistry* registry) {
  registry->add_command(
      "capture.result",
      {AtRule::kMono, SessionPolicy::kAny,
       decode_fact<CaptureResult, decode_capture_result,
                   apply_capture_result>});
  registry->add_command(
      "surface", {AtRule::kMono, SessionPolicy::kEventProducing,
                  decode_fact<SurfaceFact, decode_surface_fact,
                              apply_surface>});
  registry->add_timers("capture.", fire_capture_timer);
  registry->add_teardown(TeardownStage::kCaptureWork, teardown_capture_work);
  registry->on_session_started(start_session_captures);
  registry->on_foregrounded_before_record(resume_captures);
}

}  // namespace engine
}  // namespace tugboat
