#include "navigation_facts.h"

#include <utility>

#include "name_table.h"

namespace tugboat {
namespace engine {

namespace {

constexpr NamedValue<NavigationKind> kKinds[] = {
    {"push", NavigationKind::kPush},
    {"pop", NavigationKind::kPop},
    {"replace", NavigationKind::kReplace},
    {"remove", NavigationKind::kRemove},
    {"session_start", NavigationKind::kSessionStart},
};

constexpr NamedValue<NavigationKind> kWireNames[] = {
    {"route_push", NavigationKind::kPush},
    {"route_pop", NavigationKind::kPop},
    {"route_replace", NavigationKind::kReplace},
    {"route_remove", NavigationKind::kRemove},
    {"session_start", NavigationKind::kSessionStart},
};

constexpr NamedValue<OverlayKind> kOverlayKinds[] = {
    {"page", OverlayKind::kPage},
    {"sheet", OverlayKind::kSheet},
    {"dialog", OverlayKind::kDialog},
    {"popup", OverlayKind::kPopup},
    {"unknown", OverlayKind::kUnknown},
};

// A day, the bound of every engine duration.
constexpr int64_t kMaxTransitionMs = 86400000;

bool decode_route(const Value& json, const std::string& path, FactRoute* out,
                  Error* error) {
  const ObjectReader r(json, path, error);
  if (!r.check_keys({"instanceId", "name", "type", "overlayKind",
                     "transitionMs"}) ||
      !read_non_empty(r, "instanceId", &out->instance_id) ||
      !r.opt_string("name", &out->name) ||
      !read_non_empty(r, "type", &out->type) ||
      !read_named(r, "overlayKind", kOverlayKinds, &out->overlay_kind) ||
      !read_non_negative(r, "transitionMs", &out->transition_ms)) {
    return false;
  }
  return out->transition_ms <= kMaxTransitionMs ||
         r.reject("transitionMs", "must be at most 86400000");
}

bool decode_departing(const ObjectReader& parent, NavigationFact* out,
                      Error* error) {
  const Value* json = nullptr;
  if (!parent.opt_object("departing", &json)) return false;
  if (json == nullptr) return true;
  const ObjectReader r(*json, parent.child("departing"), error);
  std::string instance_id;
  OptString name;
  OptString type;
  // `name` and `type` are validated but not read: the id finds the stack
  // entry, and `route_change`'s `from*` fields come from the visible route,
  // as in Dart (none for a session's first navigation).
  if (!r.check_keys({"instanceId", "name", "type"}) ||
      !read_non_empty(r, "instanceId", &instance_id) ||
      !r.opt_string("name", &name) || !r.opt_string("type", &type)) {
    return false;
  }
  out->departing_instance_id = std::move(instance_id);
  return true;
}

bool decode_parent(const ObjectReader& r, NavigationFact* out) {
  if (!r.opt_string("parentNavigatorId", &out->parent_navigator_id)) {
    return false;
  }
  if (!out->parent_navigator_id) return true;
  if (out->parent_navigator_id->empty()) {
    return r.reject("parentNavigatorId", "must not be empty");
  }
  return *out->parent_navigator_id != out->navigator_id ||
         r.reject("parentNavigatorId", "must differ from navigatorId");
}

}  // namespace

const char* navigation_wire_name(NavigationKind kind) {
  return name_of(kWireNames, kind);
}

const char* overlay_kind_name(OverlayKind kind) {
  return name_of(kOverlayKinds, kind);
}

RouteIdentity route_identity(const std::optional<FactRoute>& route) {
  RouteIdentity identity;
  if (!route) return identity;
  identity.route_named = route->name && !route->name->empty();
  identity.route_name = identity.route_named ? route->name : std::nullopt;
  identity.route_type = route->type;
  identity.route = identity.route_named ? *route->name : route->type;
  return identity;
}

bool decode_routes(const ObjectReader& parent, NavigationFact* out,
                   Error* error) {
  const Value* json = parent.get("routes");
  if (json == nullptr) return true;
  if (!json->is_array()) {
    return parent.reject("routes", "must be an array");
  }
  const std::vector<Value>& items = json->items();
  if (items.empty()) {
    return parent.reject("routes", "must not be empty");
  }
  out->routes.reserve(items.size());
  for (size_t i = 0; i < items.size(); ++i) {
    FactRoute route;
    const std::string path =
        parent.child("routes") + "[" + std::to_string(i) + "]";
    if (!decode_route(items[i], path, &route, error)) return false;
    if (route.transition_ms != 0) {
      const std::string transition_path = path + ".transitionMs";
      return parent.reject(transition_path.c_str(),
                           "must be 0 for session_start routes");
    }
    out->routes.push_back(std::move(route));
  }
  return true;
}

bool decode_navigation_fact(const Value& input, const std::string& path,
                            NavigationFact* out, Error* error) {
  const ObjectReader r(input, path, error);
  const Value* route = nullptr;
  if (!r.check_keys({"kind", "navigatorId", "parentNavigatorId", "route",
                     "departing", "routes"}) ||
      !read_named(r, "kind", kKinds, &out->kind) ||
      !read_non_empty(r, "navigatorId", &out->navigator_id) ||
      !decode_parent(r, out) || !r.opt_object("route", &route) ||
      !decode_departing(r, out, error) || !decode_routes(r, out, error)) {
    return false;
  }
  if (out->kind == NavigationKind::kSessionStart) {
    if (route != nullptr) {
      return r.reject("route", "must be absent for session_start");
    }
    if (out->departing_instance_id) {
      return r.reject("departing", "must be absent for session_start");
    }
    if (out->routes.empty()) {
      return r.reject("routes", "is required for session_start");
    }
    return true;
  }
  if (!out->routes.empty()) {
    return r.reject("routes", "must be absent unless kind is session_start");
  }
  if (route == nullptr) return true;
  FactRoute decoded;
  if (!decode_route(*route, r.child("route"), &decoded, error)) return false;
  out->route = std::move(decoded);
  return true;
}

}  // namespace engine
}  // namespace tugboat
