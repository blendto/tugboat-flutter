// Navigation (docs/stateful-engine.md section 8.1): the `navigation` fact,
// the `navigation.` timers, the route-capture teardown stage, and the
// per-session reset. Its state is `EngineState::navigation`
// (navigation_state.h); route captures go through the capture seam.
#include <optional>
#include <string>

#include "engine_state.h"
#include "fact_command.h"
#include "modules.h"
#include "navigation_facts.h"
#include "route_capture.h"
#include "route_change.h"

namespace tugboat {
namespace engine {

namespace {

// Dart `route()`: event-producing, so it only applies with a live session.
void apply_navigation(const ModuleRegistry&, EngineState* state,
                      const NavigationFact& fact, const At& at, Output* out) {
  Turn turn{state, state->live_session(), at, out};
  if (fact.kind == NavigationKind::kSessionStart) {
    std::optional<VisibleRouteChange> change =
        resolve_session_start_route_change(turn, fact);
    if (!change) return;
    const std::string event_id = state->ids.next("event");
    record_route_change(turn, event_id, *change, std::nullopt,
                        RouteChangeCapture{});
    return;
  }
  std::optional<VisibleRouteChange> change = resolve_route_change(turn, fact);
  if (change) start_route_capture(turn, std::move(*change));
}

void fire_navigation_timer(const std::string& timer_id, const At& at,
                           EngineState* state, Output* out) {
  Session* session = state->live_session();
  if (session == nullptr) return;
  Turn turn{state, session, at, out};
  std::string epoch;
  if (timer_key(timer_id, kRouteDeadlinePrefix, &epoch)) {
    route_deadline_reached(turn, epoch);
  } else if (timer_key(timer_id, kRouteTimeoutPrefix, &epoch)) {
    route_barrier_timed_out(turn, epoch);
  }
}

void teardown_route_captures(TeardownCause cause, const At& at,
                             EngineState* state, Output* out) {
  cancel_route_captures(state, at, out, teardown_cancel_reason(cause));
}

// Dart `start()`: navigator ids, stacks, and the visible route are per
// session; the route epoch is not.
void reset_for_session(const At&, EngineState* state, Output*) {
  NavigationState& navigation = state->navigation;
  navigation.registry.clear();
  navigation.visible = VisibleRoute{};
  navigation.visual_generation = 0;
}

}  // namespace

void register_navigation_module(ModuleRegistry* registry) {
  registry->add_command(
      "navigation",
      {AtRule::kMono, SessionPolicy::kEventProducing,
       decode_fact<NavigationFact, decode_navigation_fact,
                   apply_navigation>});
  registry->add_timers("navigation.", fire_navigation_timer);
  registry->add_teardown(TeardownStage::kRouteCaptures,
                         teardown_route_captures);
  registry->on_session_started(reset_for_session);
  registry->add_engine_event_type("route_change");
}

}  // namespace engine
}  // namespace tugboat
