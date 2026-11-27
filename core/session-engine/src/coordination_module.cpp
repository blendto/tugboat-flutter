// Coordination (coordination.h): after every applied command the engine
// runs the work that command deferred (capture answers, route barrier
// resumes, the publication queue), so waiters see the state the command
// left, as Dart microtasks do.
#include "coordination.h"
#include "modules.h"

namespace tugboat {
namespace engine {

void register_coordination_module(ModuleRegistry* registry) {
  registry->on_after_command(run_deferred);
}

}  // namespace engine
}  // namespace tugboat
