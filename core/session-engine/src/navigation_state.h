// Navigation state (docs/stateful-engine.md section 8.1): the navigator
// stacks, the visible route, the route epoch, and the route-capture work.
// Owned by the navigation module (navigation_module.cpp); the capture
// scheduler and frame provenance live in the capture seam
// (`EngineState::captures`). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_NAVIGATION_STATE_H
#define TUGBOAT_SESSION_ENGINE_NAVIGATION_STATE_H

#include <cstdint>
#include <map>
#include <set>
#include <string>

#include "navigator_registry.h"
#include "ordered_map.h"
#include "route_change.h"
#include "route_work.h"

namespace tugboat {
namespace engine {

// Dart `_activeRouteCaptures` and the state that follows them.
struct RouteCaptures {
  // Active work by navigator, in start order (Dart `LinkedHashMap`).
  OrderedMap<std::string, RouteWorkPtr> active;
  // The navigator of the most recently started active work.
  OptString latest_key;
  // Work a claimed interaction has not consumed yet, by interaction id.
  std::map<std::string, RouteWorkPtr> causal;
  // Interactions whose claimed route was superseded by another cause.
  std::set<std::string> superseded_interactions;
  // Navigators in a transition, whose captures are suppressed (change C11:
  // per navigator, where Dart has one `_skipCapture` flag).
  std::set<std::string> transitioning;
};

struct NavigationState {
  NavigatorRegistry registry;
  VisibleRoute visible;
  // True after the first live push, pop, replace, or visible removal in the session.
  bool live_navigation_seen = false;
  // Never reset, so frames of an old session never match a new one.
  int64_t route_epoch = 0;
  int64_t visual_generation = 0;
  RouteCaptures routes;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_NAVIGATION_STATE_H
