#include "engine_state.h"
#include "fact_command.h"
#include "modules.h"
#include "scene_inventory.h"
#include "scene_resample.h"
#include "turn.h"

namespace tugboat {
namespace engine {

namespace {

// The fact `scene.frame {}`: a frame was drawn while the re-sample watch is
// armed (`scene.watch {armed: true}`).
struct SceneFrameFact {};

bool decode_scene_frame_fact(const Value& json, const std::string& path,
                             SceneFrameFact*, Error* error) {
  const ObjectReader r(json, path, error);
  return r.check_keys({});
}

void apply_scene_inventory_fact(const ModuleRegistry&, EngineState* state,
                                const SceneInventoryFact& fact, const At& at,
                                Output* out) {
  Turn turn{state, state->live_session(), at, out};
  apply_scene_inventory(turn, fact);
}

void apply_scene_frame_fact(const ModuleRegistry&, EngineState* state,
                            const SceneFrameFact&, const At& at, Output* out) {
  Turn turn{state, state->live_session(), at, out};
  on_scene_frame(turn);
}

void fire_scene_timer(const std::string& timer_id, const At& at,
                      EngineState* state, Output* out) {
  Session* session = state->live_session();
  if (session == nullptr) return;
  if (timer_id != kSceneWindowTimer) return;
  Turn turn{state, session, at, out};
  on_scene_window(turn);
}

// The watch ends on a lifecycle pause or hide and at session end; a new
// session starts with nothing sent.
void stop_watch_hook(const At&, EngineState* state, Output* out) {
  stop_resample_watch(state, out);
}

void reset_for_session(const At&, EngineState* state, Output*) {
  reset_resample(state);
}

}  // namespace

void register_scene_inventory_module(ModuleRegistry* registry) {
  registry->add_command(
      "scene.inventory",
      {AtRule::kMono, SessionPolicy::kEventProducing,
       decode_fact<SceneInventoryFact, decode_scene_inventory_fact,
                   apply_scene_inventory_fact>});
  registry->add_command(
      "scene.frame",
      {AtRule::kMono, SessionPolicy::kEventProducing,
       decode_fact<SceneFrameFact, decode_scene_frame_fact,
                   apply_scene_frame_fact>});
  registry->add_timers("scene.", fire_scene_timer);
  registry->on_backgrounded(stop_watch_hook);
  registry->on_session_ending(stop_watch_hook);
  registry->on_session_started(reset_for_session);
  registry->add_engine_event_type("scene_inventory");
}

}  // namespace engine
}  // namespace tugboat
