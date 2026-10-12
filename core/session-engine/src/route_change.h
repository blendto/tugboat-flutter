// A visible navigation (Dart `_VisibleRouteChange`): how a `navigation`
// fact resolves against the navigator stacks and the visible route, which
// interaction it claims as its cause, and the `route_change` envelope it
// is recorded with. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ROUTE_CHANGE_H
#define TUGBOAT_SESSION_ENGINE_ROUTE_CHANGE_H

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "interaction_claims.h"
#include "models.h"
#include "navigation_facts.h"
#include "navigator_registry.h"
#include "turn.h"

namespace tugboat {
namespace engine {

// Dart `_currentRoute` and its identity, navigator, and route instance.
struct VisibleRoute {
  OptString route;
  std::optional<RouteIdentity> identity;
  OptString navigator_id;
  OptString route_instance_id;
};

// The interaction a navigation claimed as its cause.
struct RouteCause {
  std::string event_id;
  OptString target_fingerprint;  // at claim time
  std::string gesture;           // wire name at claim time
  ClaimAttribution attribution = ClaimAttribution::kDirect;
};

struct VisibleRouteChange {
  NavigationKind kind = NavigationKind::kPush;
  OptString previous_route;
  OptString destination_route;
  // Push, replace, and any navigation that names its destination change
  // the visible route; a pop or removal revealing no route does not.
  bool updates_route = false;
  RouteIdentity identity;
  std::optional<RouteIdentity> from;
  std::string navigator_id;
  OptString parent_navigator_id;
  OptString route_instance_id;
  OptString from_route_instance_id;
  int64_t stack_revision = 0;
  OverlayKind overlay_kind = OverlayKind::kUnknown;
  int64_t transition_ms = 0;
  int64_t visual_generation = 0;
  std::optional<RouteCause> cause;
  std::optional<RoutePresentation> presentation;
  std::vector<RouteSurfaceRecord> route_stack;
  bool route_stack_truncated = false;

  // The interaction it claimed, if any.
  const std::string* cause_event_id() const {
    return cause ? &cause->event_id : nullptr;
  }
};

// Dart `_resolveVisibleRouteChange`, run before the route epoch advances:
// a removal that reveals nothing new is invisible (nothing); otherwise the
// stacks are updated, the destination remembered, the visual observation
// generation advanced, and the cause claimed (`claim_interaction_cause`).
std::optional<VisibleRouteChange> resolve_route_change(
    Turn& turn, const NavigationFact& fact);

// Dart `_applyVisibleRouteChange`.
void apply_visible_route(const VisibleRouteChange& change,
                         VisibleRoute* visible);

// Dart `_RouteCaptureOutcome`: how a route's barrier ended.
enum class RouteOutcome { kCaptured, kFailed, kCancelled, kTimedOut };

// What a `route_change` event says about its capture. `outcome` is
// `captured` (no `captureOutcome`), `failed`, or `timed_out`.
struct RouteChangeCapture {
  RouteOutcome outcome = RouteOutcome::kCaptured;
  OptString failure;     // `captureFailure`
  OptString request_id;  // `captureRequestId`
};

// Dart `_emitRouteChange`: records `route_change` `event_id` on the evidence
// stream with result `navigated` (or `unknown` when timed out). The cause's
// live fingerprint and gesture come from the still-unpublished interaction.
void record_route_change(Turn& turn, const std::string& event_id,
                         const VisibleRouteChange& change,
                         const OptString& after_frame,
                         const RouteChangeCapture& capture);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_ROUTE_CHANGE_H
