#include "engine_state.h"
#include "fact_command.h"
#include "modules.h"
#include "scene_inventory.h"
#include "turn.h"

namespace tugboat {
namespace engine {

namespace {

void apply_scene_inventory_fact(const ModuleRegistry&, EngineState* state,
                                const SceneInventoryFact& fact, const At& at,
                                Output* out) {
  Turn turn{state, state->live_session(), at, out};
  apply_scene_inventory(turn, fact);
}

}  // namespace

void register_scene_inventory_module(ModuleRegistry* registry) {
  registry->add_command(
      "scene.inventory",
      {AtRule::kMono, SessionPolicy::kEventProducing,
       decode_fact<SceneInventoryFact, decode_scene_inventory_fact,
                   apply_scene_inventory_fact>});
  registry->add_engine_event_type("scene_inventory");
}

}  // namespace engine
}  // namespace tugboat
