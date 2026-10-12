#include "modules.h"

namespace tugboat {
namespace engine {

ModuleRegistry build_module_registry() {
  ModuleRegistry registry;
  register_stateless_module(&registry);
  register_engine_module(&registry);
  register_session_module(&registry);
  register_evidence_module(&registry);
  register_delivery_module(&registry);
  register_interaction_module(&registry);
  register_navigation_module(&registry);
  register_capture_module(&registry);
  register_coordination_module(&registry);
  return registry;
}

const ModuleRegistry& module_registry() {
  static const ModuleRegistry registry = build_module_registry();
  return registry;
}

}  // namespace engine
}  // namespace tugboat
