// The navigation fact of docs/stateful-engine.md section 8.1, as a typed
// model with its strict decoder.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_NAVIGATION_FACTS_H
#define TUGBOAT_SESSION_ENGINE_NAVIGATION_FACTS_H

#include <cstdint>
#include <optional>
#include <string>

#include "json.h"
#include "models.h"
#include "reader.h"

namespace tugboat {
namespace engine {

// Dart `_RouteNavigationKind`.
enum class NavigationKind { kPush, kPop, kReplace, kRemove };

// `route_push`, `route_pop`, `route_replace`, `route_remove`: the
// `route_change.data.navigation` value.
const char* navigation_wire_name(NavigationKind kind);

// Dart `TugboatOverlayKind`; the adapter classifies its toolkit's routes.
enum class OverlayKind { kPage, kSheet, kDialog, kPopup, kUnknown };

const char* overlay_kind_name(OverlayKind kind);

// A route as the adapter reports it. `name` is the toolkit route name (an
// empty name counts as unnamed); `type` is the toolkit route type.
struct FactRoute {
  std::string instance_id;  // opaque, stable for the route's lifetime
  OptString name;
  std::string type;
  OverlayKind overlay_kind = OverlayKind::kPage;
  int64_t transition_ms = 0;
};

// Dart `TugboatRouteIdentity`: `route` is the name when non-empty, else the
// type; no route is `unknown` and unnamed.
struct RouteIdentity {
  OptString route;
  OptString route_name;
  std::string route_type = "unknown";
  bool route_named = false;
};

RouteIdentity route_identity(const std::optional<FactRoute>& route);

// `navigation {kind, navigatorId, parentNavigatorId?, route?, departing?}`.
// `route` is the destination: the pushed route, the replacement, or the
// route a pop or removal reveals (absent when none is). `departing
// {instanceId, name?, type?}` names the route leaving or covered; only its
// id is read.
struct NavigationFact {
  NavigationKind kind = NavigationKind::kPush;
  std::string navigator_id;
  OptString parent_navigator_id;
  std::optional<FactRoute> route;
  OptString departing_instance_id;
};

bool decode_navigation_fact(const Value& input, const std::string& path,
                            NavigationFact* out, Error* error);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_NAVIGATION_FACTS_H
