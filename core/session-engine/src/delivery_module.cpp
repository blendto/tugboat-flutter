// Collector delivery (docs/stateful-engine.md section 7). Its state is
// `EngineState::delivery` (delivery_state.h).
#include "modules.h"

namespace tugboat {
namespace engine {

void register_delivery_module(ModuleRegistry* /*registry*/) {}

}  // namespace engine
}  // namespace tugboat
