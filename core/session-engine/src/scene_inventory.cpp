#include "scene_inventory.h"

#include <algorithm>
#include <utility>

#include "engine_state.h"
#include "evidence.h"
#include "recorder.h"
#include "text.h"
#include "turn.h"

namespace tugboat {
namespace engine {

namespace {

constexpr const char* kTierInteractive = "interactive";
constexpr const char* kTierContent = "content";
constexpr double kBoundsEpsilon = 1e-9;
constexpr size_t kMaxAliases = 16;
constexpr size_t kMaxActions = 16;

bool decode_bounds(const ObjectReader& r, NormalizedBounds* out, Error* error) {
  const Value* json = nullptr;
  if (!r.req_object("boundsNorm", &json)) return false;
  const ObjectReader bounds(*json, r.child("boundsNorm"), error);
  if (!bounds.check_keys({"left", "top", "width", "height"}) ||
      !bounds.req_double("left", &out->left) ||
      !bounds.req_double("top", &out->top) ||
      !bounds.req_double("width", &out->width) ||
      !bounds.req_double("height", &out->height)) {
    return false;
  }
  if (out->left < 0 || out->left > 1 || out->top < 0 || out->top > 1 ||
      out->width <= 0 || out->height <= 0 ||
      out->left + out->width > 1 + kBoundsEpsilon ||
      out->top + out->height > 1 + kBoundsEpsilon) {
    return r.reject("boundsNorm", "out of range");
  }
  return true;
}

std::string bound_string(std::string value) {
  if (!utf16_longer_than(value, ParameterLimits::kMaxStringLength)) {
    return value;
  }
  return utf16_prefix(value, ParameterLimits::kMaxStringLength);
}

bool decode_string_array(const ObjectReader& r, const char* key,
                         std::vector<std::string>* out, Error* error) {
  const Value* json = r.get(key);
  if (json == nullptr) return true;
  if (!json->is_array()) {
    return r.reject(key, "expected array");
  }
  const std::string base = r.child(key);
  for (size_t i = 0; i < json->items().size(); ++i) {
    const Value& item = json->items()[i];
    if (!item.is_string()) {
      return invalid(error, base + "[" + std::to_string(i) + "]",
                     "expected string");
    }
    out->push_back(item.as_string());
  }
  return true;
}

bool decode_element(const Value& json, const std::string& path,
                    SceneInventoryElement* out, Error* error) {
  const ObjectReader r(json, path, error);
  std::string tier;
  if (!r.check_keys({"fingerprint", "canonicalPath", "widgetType", "role",
                     "actions", "enabled", "boundsNorm", "tier", "aliases"}) ||
      !r.req_string("fingerprint", &out->fingerprint) ||
      !r.req_string("canonicalPath", &out->canonical_path) ||
      !r.opt_string("widgetType", &out->widget_type) ||
      !r.opt_string("role", &out->role) ||
      !decode_string_array(r, "actions", &out->actions, error) ||
      !r.opt_bool("enabled", &out->enabled) || !decode_bounds(r, &out->bounds_norm, error) ||
      !r.req_string("tier", &tier) ||
      !decode_string_array(r, "aliases", &out->aliases, error)) {
    return false;
  }
  // `canonicalPath` may be empty, as on `targetAnchor`: a route root's own
  // path is "".
  if (out->fingerprint.empty()) {
    return r.reject("fingerprint", "must not be empty");
  }
  if (tier != kTierInteractive && tier != kTierContent) {
    return r.reject("tier", "expected interactive or content");
  }
  out->tier = std::move(tier);
  return true;
}

void bound_element(SceneInventoryElement* element) {
  element->fingerprint = bound_string(element->fingerprint);
  element->canonical_path = bound_string(element->canonical_path);
  if (element->widget_type) {
    *element->widget_type = bound_string(*element->widget_type);
  }
  if (element->role) {
    *element->role = bound_string(*element->role);
  }
  for (std::string& action : element->actions) {
    action = bound_string(action);
  }
  if (element->actions.size() > kMaxActions) {
    element->actions.resize(kMaxActions);
  }
  if (element->aliases.size() > kMaxAliases) {
    element->aliases.resize(kMaxAliases);
  }
  for (std::string& alias : element->aliases) {
    alias = bound_string(alias);
  }
}

Value bounds_json(const NormalizedBounds& bounds) {
  Value json = Value::object();
  json.set("left", Value::number(bounds.left));
  json.set("top", Value::number(bounds.top));
  json.set("width", Value::number(bounds.width));
  json.set("height", Value::number(bounds.height));
  return json;
}

Value element_json(const SceneInventoryElement& element) {
  Value json = Value::object();
  json.set("fingerprint", Value::string(element.fingerprint));
  json.set("canonicalPath", Value::string(element.canonical_path));
  if (element.widget_type) {
    json.set("widgetType", Value::string(*element.widget_type));
  }
  if (element.role) {
    json.set("role", Value::string(*element.role));
  }
  if (!element.actions.empty()) {
    Value actions = Value::array();
    for (const std::string& action : element.actions) {
      actions.push(Value::string(action));
    }
    json.set("actions", std::move(actions));
  }
  if (element.enabled) {
    json.set("enabled", Value::boolean(*element.enabled));
  }
  json.set("boundsNorm", bounds_json(element.bounds_norm));
  json.set("tier", Value::string(element.tier));
  if (!element.aliases.empty()) {
    Value aliases = Value::array();
    for (const std::string& alias : element.aliases) {
      aliases.push(Value::string(alias));
    }
    json.set("aliases", std::move(aliases));
  }
  return json;
}

std::string dedupe_key(const std::string& route_key,
                       const std::string& inventory_hash,
                       const std::string& scroll_key) {
  return route_key + "|" + inventory_hash + "|" + scroll_key;
}

}  // namespace

bool decode_scene_inventory_fact(const Value& json, const std::string& path,
                                 SceneInventoryFact* out, Error* error) {
  const ObjectReader r(json, path, error);
  const Value* elements = nullptr;
  if (!r.check_keys({"routeKey", "elements", "scrollKey", "totalElements"}) ||
      !r.opt_string("routeKey", &out->route_key) ||
      !r.opt_string("scrollKey", &out->scroll_key) ||
      !r.opt_int("totalElements", &out->total_elements) ||
      !r.req_array("elements", &elements)) {
    return false;
  }
  if (out->total_elements && *out->total_elements < 0) {
    return r.reject("totalElements", "must not be negative");
  }
  const std::string elements_path = r.child("elements");
  for (size_t i = 0; i < elements->items().size(); ++i) {
    SceneInventoryElement element;
    if (!decode_element(elements->items()[i],
                        elements_path + "[" + std::to_string(i) + "]", &element,
                        error)) {
      return false;
    }
    out->elements.push_back(std::move(element));
  }
  return true;
}

void record_scene_inventory(Turn& turn, const std::string& route_key,
                            const std::string& inventory_hash,
                            const std::string& scroll_key, Value data,
                            std::optional<int64_t> truncated_from) {
  EngineState& state = *turn.state;
  const std::string key = dedupe_key(route_key, inventory_hash, scroll_key);
  if (!state.interactions.emitted_inventories.insert(key).second) return;
  if (truncated_from) {
    Diagnostic diagnostic;
    diagnostic.data.set("component", Value::string("scene_inventory"));
    diagnostic.data.set("truncatedFrom", Value::integer(*truncated_from));
    record_diagnostic(turn.state, turn.at, turn.out, std::move(diagnostic));
  }
  Event event = make_event(&state, *turn.session, "scene_inventory",
                           turn.at.mono_us);
  event.data = std::move(data);
  record_event(&state, *turn.session, std::move(event), true, turn.out);
}

void apply_scene_inventory(Turn& turn, const SceneInventoryFact& fact) {
  if (!turn.state->config.capabilities.native_scene_inventory) {
    return;
  }
  if (fact.elements.empty()) {
    return;
  }
  // C20: keep the first `maxSceneInventoryElements`; the diagnostic reports
  // what the adapter found (`totalElements`) or sent, whichever is larger.
  const size_t limit = static_cast<size_t>(
      turn.state->config.limits.max_scene_inventory_elements);
  const int64_t found = std::max<int64_t>(
      fact.total_elements.value_or(0),
      static_cast<int64_t>(fact.elements.size()));
  std::optional<int64_t> truncated_from;
  if (found > static_cast<int64_t>(limit)) truncated_from = found;
  const size_t kept = std::min(fact.elements.size(), limit);
  std::vector<SceneInventoryElement> elements(fact.elements.begin(),
                                              fact.elements.begin() + kept);
  std::vector<std::string> fingerprints;
  fingerprints.reserve(elements.size());
  Value elements_json = Value::array();
  for (SceneInventoryElement& element : elements) {
    bound_element(&element);
    fingerprints.push_back(element.fingerprint);
    elements_json.push(element_json(element));
  }
  const std::string route_key = fact.route_key.value_or("");
  const std::string scroll_key = fact.scroll_key.value_or("");
  const std::string hash = inventory_hash_from_fingerprints(std::move(fingerprints));
  Value data = Value::object();
  data.set("inventoryHash", Value::string(hash));
  data.set("routeKey", Value::string(route_key));
  data.set("elements", std::move(elements_json));
  if (!scroll_key.empty()) {
    data.set("scrollKey", Value::string(scroll_key));
  }
  record_scene_inventory(turn, route_key, hash, scroll_key, std::move(data),
                         truncated_from);
}

}  // namespace engine
}  // namespace tugboat
