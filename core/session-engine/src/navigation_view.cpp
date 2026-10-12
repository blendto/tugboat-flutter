#include "navigation_view.h"

#include "engine_state.h"

namespace tugboat {
namespace engine {

RouteStamp current_route_stamp(const EngineState& state) {
  const NavigationState& navigation = state.navigation;
  RouteStamp stamp;
  stamp.route_epoch = navigation.route_epoch;
  stamp.route = navigation.visible.route;
  stamp.navigator_id = navigation.visible.navigator_id;
  stamp.route_instance_id = navigation.visible.route_instance_id;
  return stamp;
}

RequestContext current_request_context(const EngineState& state,
                                       FrameTrigger trigger) {
  const NavigationState& navigation = state.navigation;
  const BoundaryObservation& boundary = state.captures.boundary();
  RequestContext context;
  if (state.session) context.session_id = state.session->id();
  context.route_epoch = navigation.route_epoch;
  context.route = navigation.visible.route;
  context.navigator_id = navigation.visible.navigator_id;
  context.route_instance_id = navigation.visible.route_instance_id;
  context.boundary_generation = boundary.generation;
  context.boundary = boundary.rect;
  context.trigger = trigger;
  return context;
}

bool transition_suppresses(const EngineState& state,
                           const OptString& navigator_id) {
  return navigator_id &&
         state.navigation.routes.transitioning.count(*navigator_id) != 0;
}

RouteWorkPtr latest_route_capture(const EngineState& state) {
  const RouteCaptures& routes = state.navigation.routes;
  if (!routes.latest_key) return nullptr;
  const RouteWorkPtr* work = routes.active.find(*routes.latest_key);
  return work == nullptr ? nullptr : *work;
}

RouteWorkPtr causal_route_capture(const EngineState& state,
                                  const std::string& interaction_id) {
  const RouteWorkPtr latest = latest_route_capture(state);
  const std::string* cause =
      latest == nullptr ? nullptr : latest->change.cause_event_id();
  if (cause != nullptr && *cause == interaction_id) return latest;
  const auto& causal = state.navigation.routes.causal;
  const auto it = causal.find(interaction_id);
  return it == causal.end() ? nullptr : it->second;
}

bool cause_was_superseded(const EngineState& state,
                          const std::string& interaction_id) {
  return state.navigation.routes.superseded_interactions.count(
             interaction_id) != 0;
}

void clear_causal_route_state(EngineState* state,
                              const std::string& interaction_id) {
  RouteCaptures& routes = state->navigation.routes;
  routes.causal.erase(interaction_id);
  routes.superseded_interactions.erase(interaction_id);
}

}  // namespace engine
}  // namespace tugboat
