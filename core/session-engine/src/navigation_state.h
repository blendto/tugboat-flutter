// Navigation and capture coordination state (docs/stateful-engine.md
// section 8): navigator stacks, route-capture work, the capture scheduler,
// and frame provenance. Owned by the navigation module
// (navigation_module.cpp). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_NAVIGATION_STATE_H
#define TUGBOAT_SESSION_ENGINE_NAVIGATION_STATE_H

namespace tugboat {
namespace engine {

struct NavigationState {};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_NAVIGATION_STATE_H
