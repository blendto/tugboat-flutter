#include "route_change.h"

#include <utility>

#include "engine_state.h"
#include "recorder.h"

namespace tugboat {
namespace engine {

namespace {

// Dart's `({navigatorId, parentNavigatorId, routeInstanceId,
// fromRouteInstanceId, stackRevision})` record.
struct RouteSurface {
  std::string navigator_id;
  OptString parent_navigator_id;
  OptString route_instance_id;
  OptString from_route_instance_id;
  int64_t stack_revision = 0;
};

// Dart `_resolveBoundRouteSurface`: push, replace, or pop/remove.
RouteSurface resolve_surface(NavigatorRegistry* registry,
                             const VisibleRoute& visible,
                             const NavigationFact& fact) {
  RouteSurface surface;
  surface.navigator_id =
      registry->navigator(fact.navigator_id, fact.parent_navigator_id);
  surface.parent_navigator_id = registry->parent_of(surface.navigator_id);
  const OptString destination =
      fact.route ? OptString(registry->route_instance(fact.route->instance_id))
                 : std::nullopt;
  const OptString departing =
      registry->peek_route_instance(fact.departing_instance_id);
  switch (fact.kind) {
    case NavigationKind::kPush:
      surface.route_instance_id = destination;
      surface.from_route_instance_id = visible.route_instance_id;
      if (destination) {
        surface.stack_revision =
            registry->push(surface.navigator_id, *destination);
      }
      break;
    case NavigationKind::kReplace:
      surface.route_instance_id = destination;
      surface.from_route_instance_id =
          departing ? departing : visible.route_instance_id;
      if (destination) {
        surface.stack_revision =
            registry->replace_top(surface.navigator_id, *destination);
      }
      break;
    case NavigationKind::kPop:
    case NavigationKind::kRemove:
      surface.from_route_instance_id =
          departing ? departing : visible.route_instance_id;
      surface.stack_revision = registry->pop(
          surface.navigator_id, surface.from_route_instance_id);
      surface.route_instance_id =
          destination ? destination : registry->top(surface.navigator_id);
      break;
    case NavigationKind::kSessionStart:
      break;
  }
  return surface;
}

// Dart `_routeCauseFromClaim`.
std::optional<RouteCause> cause_from_claim(const EngineState& state,
                                           const InteractionClaim& claim) {
  if (claim.outcome != ClaimOutcome::kClaimed) return std::nullopt;
  const TransactionPtr tx =
      state.interactions.registry.find(claim.interaction_id);
  RouteCause cause;
  cause.event_id = claim.interaction_id;
  cause.attribution = claim.attribution;
  if (tx != nullptr) {
    if (tx->target_anchor && tx->target_anchor->fingerprint &&
        !tx->target_anchor->fingerprint->empty()) {
      cause.target_fingerprint = tx->target_anchor->fingerprint;
    }
    cause.gesture = gesture_name(tx->gesture);
  }
  return cause;
}

bool is_invisible_removal(const NavigationFact& fact,
                          const RouteIdentity& identity,
                          const VisibleRoute& visible) {
  return fact.kind == NavigationKind::kRemove &&
         (!identity.route || identity.route == visible.route);
}

void put_identity(Value* data, const VisibleRouteChange& change) {
  put_opt(data, "routeName", change.identity.route_name);
  data->set("routeType", Value::string(change.identity.route_type));
  data->set("routeNamed", Value::boolean(change.identity.route_named));
  if (change.kind == NavigationKind::kSessionStart || !change.from) return;
  put_opt(data, "fromRouteName", change.from->route_name);
  data->set("fromRouteType", Value::string(change.from->route_type));
  data->set("fromRouteNamed", Value::boolean(change.from->route_named));
}

void put_surface(Value* data, const VisibleRouteChange& change) {
  data->set("navigatorId", Value::string(change.navigator_id));
  put_opt(data, "parentNavigatorId", change.parent_navigator_id);
  put_opt(data, "routeInstanceId", change.route_instance_id);
  if (change.kind != NavigationKind::kSessionStart) {
    put_opt(data, "fromRouteInstanceId", change.from_route_instance_id);
  }
  data->set("stackRevision", Value::integer(change.stack_revision));
  data->set("overlayKind",
            Value::string(overlay_kind_name(change.overlay_kind)));
  data->set("visualObservationGeneration",
            Value::integer(change.visual_generation));
  data->set("navigationOrigin",
            Value::string(change.cause ? "interaction"
                                       : "automatic_or_unknown"));
}

void put_cause(Value* data, const VisibleRouteChange& change) {
  if (!change.cause) return;
  data->set("causeEventId", Value::string(change.cause->event_id));
  data->set("causedByInteractionId", Value::string(change.cause->event_id));
  // Dart `claimWireName`.
  data->set("interactionAttribution",
            Value::string(change.cause->attribution ==
                                  ClaimAttribution::kDelayedLikely
                              ? "delayed_likely"
                              : "same_turn"));
}

Value stack_entry_json(const RouteSurfaceRecord& record) {
  Value entry = Value::object();
  entry.set("routeInstanceId", Value::string(record.instance_id));
  entry.set("route", Value::string(record.route));
  entry.set("routeNamed", Value::boolean(record.route_named));
  entry.set("overlayKind",
            Value::string(overlay_kind_name(record.overlay_kind)));
  entry.set("navigatorId", Value::string(record.navigator_id));
  return entry;
}

void put_presentation(Value* data, const VisibleRouteChange& change) {
  if (change.presentation) {
    if (const auto& over = change.presentation->presented_over) {
      data->set("presentedOverRoute", Value::string(over->route));
      data->set("presentedOverRouteInstanceId",
                Value::string(over->instance_id));
      data->set("presentedOverOverlayKind",
                Value::string(overlay_kind_name(over->overlay_kind)));
    }
    if (const auto& host = change.presentation->host_page) {
      data->set("hostPageRoute", Value::string(host->route));
      data->set("hostPageRouteInstanceId", Value::string(host->instance_id));
    }
  }
  if (!change.route_stack.empty()) {
    Value stack = Value::array();
    for (const RouteSurfaceRecord& record : change.route_stack) {
      stack.push(stack_entry_json(record));
    }
    data->set("routeStack", std::move(stack));
  }
  if (change.route_stack_truncated) {
    data->set("routeStackTruncated", Value::boolean(true));
  }
}

// Dart `_liveRouteCauseFingerprint`: the cause's fingerprint and gesture as
// they are now, while it is unpublished; else as they were at claim time.
void put_live_cause(Value* data, const EngineState& state,
                    const VisibleRouteChange& change) {
  if (!change.cause) return;
  const TransactionPtr tx =
      state.interactions.registry.find(change.cause->event_id);
  OptString fingerprint = change.cause->target_fingerprint;
  if (tx != nullptr && tx->target_anchor && tx->target_anchor->fingerprint) {
    fingerprint = tx->target_anchor->fingerprint;
  }
  put_non_empty(data, "causeTargetFingerprint", fingerprint);
  const std::string gesture =
      tx != nullptr ? gesture_name(tx->gesture) : change.cause->gesture;
  if (!gesture.empty()) data->set("causeGesture", Value::string(gesture));
}

}  // namespace

std::optional<VisibleRouteChange> resolve_route_change(
    Turn& turn, const NavigationFact& fact) {
  EngineState& state = *turn.state;
  NavigationState& navigation = state.navigation;
  const VisibleRoute& visible = navigation.visible;
  const RouteIdentity identity = route_identity(fact.route);
  if (is_invisible_removal(fact, identity, visible)) return std::nullopt;

  const RouteSurface surface =
      resolve_surface(&navigation.registry, visible, fact);
  const OverlayKind overlay =
      fact.route ? fact.route->overlay_kind : OverlayKind::kUnknown;
  if (fact.route && surface.route_instance_id) {
    navigation.registry.remember(*surface.route_instance_id,
                                 surface.navigator_id, identity, overlay);
  }
  ++navigation.visual_generation;
  const InteractionClaim claim =
      claim_interaction_cause(&state, turn.at, surface.navigator_id);

  VisibleRouteChange change;
  change.kind = fact.kind;
  change.updates_route = fact.kind == NavigationKind::kPush ||
                         fact.kind == NavigationKind::kReplace ||
                         identity.route.has_value();
  change.previous_route = visible.route;
  change.destination_route =
      change.updates_route ? identity.route : visible.route;
  change.identity = identity;
  change.from = visible.identity;
  change.navigator_id = surface.navigator_id;
  change.parent_navigator_id = surface.parent_navigator_id;
  change.route_instance_id = surface.route_instance_id
                                 ? surface.route_instance_id
                                 : visible.route_instance_id;
  change.from_route_instance_id = surface.from_route_instance_id;
  change.stack_revision = surface.stack_revision;
  change.overlay_kind = overlay;
  change.transition_ms = fact.route ? fact.route->transition_ms : 0;
  change.visual_generation = navigation.visual_generation;
  change.cause = cause_from_claim(state, claim);
  if (surface.route_instance_id) {
    change.presentation = navigation.registry.presentation(
        surface.navigator_id, *surface.route_instance_id, overlay,
        fact.kind == NavigationKind::kPush);
  }
  const int64_t limit = state.config.navigation.route_stack_limit;
  change.route_stack =
      navigation.registry.stack_snapshot(surface.navigator_id, limit);
  change.route_stack_truncated =
      navigation.registry.stack_truncated(surface.navigator_id, limit);
  return change;
}

std::optional<VisibleRouteChange> resolve_session_start_route_change(
    Turn& turn, const NavigationFact& fact) {
  EngineState& state = *turn.state;
  NavigationState& navigation = state.navigation;
  const std::string navigator_id =
      navigation.registry.navigator(fact.navigator_id, fact.parent_navigator_id);
  if (navigation.registry.has_stack(navigator_id)) return std::nullopt;

  const OptString parent = navigation.registry.parent_of(navigator_id);
  std::optional<FactRoute> top_route;
  std::optional<RouteIdentity> top_identity;
  OptString top_instance;
  OverlayKind top_overlay = OverlayKind::kPage;
  int64_t stack_revision = 0;

  for (const FactRoute& route : fact.routes) {
    const RouteIdentity identity = route_identity(route);
    const std::string instance =
        navigation.registry.route_instance(route.instance_id);
    stack_revision = navigation.registry.push(navigator_id, instance);
    navigation.registry.remember(instance, navigator_id, identity,
                                 route.overlay_kind);
    ++navigation.visual_generation;
    VisibleRouteChange replay;
    replay.updates_route = true;
    replay.destination_route = identity.route;
    replay.identity = identity;
    replay.navigator_id = navigator_id;
    replay.parent_navigator_id = parent;
    replay.route_instance_id = instance;
    apply_visible_route(replay, &navigation.visible);
    top_route = route;
    top_identity = identity;
    top_instance = instance;
    top_overlay = route.overlay_kind;
  }

  if (!top_route || !top_identity || !top_instance) return std::nullopt;

  const int64_t limit = state.config.navigation.route_stack_limit;
  VisibleRouteChange change;
  change.kind = NavigationKind::kSessionStart;
  change.updates_route = true;
  change.destination_route = top_identity->route;
  change.identity = *top_identity;
  change.navigator_id = navigator_id;
  change.parent_navigator_id = parent;
  change.route_instance_id = top_instance;
  change.stack_revision = stack_revision;
  change.overlay_kind = top_overlay;
  change.transition_ms = 0;
  change.visual_generation = navigation.visual_generation;
  change.presentation = navigation.registry.presentation(
      navigator_id, *top_instance, top_overlay, true);
  change.route_stack =
      navigation.registry.stack_snapshot(navigator_id, limit);
  change.route_stack_truncated =
      navigation.registry.stack_truncated(navigator_id, limit);
  return change;
}

void apply_visible_route(const VisibleRouteChange& change,
                         VisibleRoute* visible) {
  if (!change.updates_route) return;
  visible->route = change.destination_route;
  visible->identity = change.identity;
  visible->navigator_id = change.navigator_id;
  visible->route_instance_id = change.route_instance_id;
}

void record_route_change(Turn& turn, const std::string& event_id,
                         const VisibleRouteChange& change,
                         const OptString& after_frame,
                         const RouteChangeCapture& capture) {
  EngineState& state = *turn.state;
  Event event;
  event.id = event_id;
  event.at_ms = turn.now_ms();
  event.type = "route_change";
  event.stream = EventStream::kEvidence;
  event.after_frame = after_frame;
  const bool session_start = change.kind == NavigationKind::kSessionStart;
  const bool timed_out = capture.outcome == RouteOutcome::kTimedOut;
  event.result = std::string(session_start || timed_out ? "unknown" : "navigated");
  Value data = Value::object();
  if (!session_start) {
    put_opt(&data, "fromRoute", change.previous_route);
  }
  put_opt(&data, "route", change.destination_route);
  data.set("navigation", Value::string(navigation_wire_name(change.kind)));
  if (capture.outcome == RouteOutcome::kFailed) {
    data.set("captureOutcome", Value::string("failed"));
  } else if (timed_out) {
    data.set("captureOutcome", Value::string("timed_out"));
  }
  put_opt(&data, "captureFailure", capture.failure);
  put_opt(&data, "captureRequestId", capture.request_id);
  put_identity(&data, change);
  put_surface(&data, change);
  put_cause(&data, change);
  put_presentation(&data, change);
  put_live_cause(&data, state, change);
  event.data = std::move(data);
  record_event(&state, *turn.session, std::move(event), true, turn.out);
}

}  // namespace engine
}  // namespace tugboat
