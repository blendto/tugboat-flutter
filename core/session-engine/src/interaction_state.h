// Interaction state (docs/stateful-engine.md section 9): pointer and gesture
// classification, the interaction registry, scroll trackers, and deferred
// input observations. Owned by the interaction module
// (interaction_module.cpp). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_STATE_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_STATE_H

namespace tugboat {
namespace engine {

struct InteractionState {};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_STATE_H
