#include "scene_inventory.h"

#include <algorithm>
#include <utility>

#include "engine_state.h"
#include "recorder.h"
#include "text.h"
#include "turn.h"

namespace tugboat {
namespace engine {

namespace {

constexpr const char* kTierInteractive = "interactive";
constexpr const char* kTierContent = "content";

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
      out->width <= 0 || out->height <= 0 || out->left + out->width > 1 ||
      out->top + out->height > 1) {
    return bounds.reject("boundsNorm", "out of range");
  }
  return true;
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
  if (out->fingerprint.empty()) {
    return r.reject("fingerprint", "must not be empty");
  }
  if (out->canonical_path.empty()) {
    return r.reject("canonicalPath", "must not be empty");
  }
  if (tier != kTierInteractive && tier != kTierContent) {
    return r.reject("tier", "expected interactive or content");
  }
  out->tier = std::move(tier);
  return true;
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
                       const std::string& inventory_hash) {
  return route_key + "|" + inventory_hash + "|";
}

}  // namespace

bool decode_scene_inventory_fact(const Value& json, const std::string& path,
                                 SceneInventoryFact* out, Error* error) {
  const ObjectReader r(json, path, error);
  const Value* elements = nullptr;
  if (!r.check_keys({"routeKey", "elements"}) ||
      !r.opt_string("routeKey", &out->route_key) ||
      !r.req_array("elements", &elements)) {
    return false;
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

std::string inventory_hash_for_elements(
    const std::vector<SceneInventoryElement>& elements) {
  std::vector<std::string> fingerprints;
  fingerprints.reserve(elements.size());
  for (const SceneInventoryElement& element : elements) {
    fingerprints.push_back(element.fingerprint);
  }
  std::sort(fingerprints.begin(), fingerprints.end(), compare_utf16);
  std::string joined;
  for (size_t i = 0; i < fingerprints.size(); ++i) {
    if (i > 0) joined.push_back('|');
    joined += fingerprints[i];
  }
  return label_hash(joined);
}

Value scene_inventory_event_data(const std::string& route_key,
                                 const std::vector<SceneInventoryElement>& elements) {
  Value data = Value::object();
  data.set("routeKey", Value::string(route_key));
  data.set("inventoryHash",
           Value::string(inventory_hash_for_elements(elements)));
  Value elements_json = Value::array();
  for (const SceneInventoryElement& element : elements) {
    elements_json.push(element_json(element));
  }
  data.set("elements", std::move(elements_json));
  return data;
}

void record_scene_inventory(Turn& turn, Value data) {
  EngineState& state = *turn.state;
  const Value* route = data.find("routeKey");
  const Value* hash = data.find("inventoryHash");
  if (route == nullptr || !route->is_string() || hash == nullptr ||
      !hash->is_string()) {
    return;
  }
  const std::string key = dedupe_key(route->as_string(), hash->as_string());
  if (!state.interactions.emitted_inventories.insert(key).second) return;
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
  const int64_t max_elements = turn.state->config.limits.max_scene_inventory_elements;
  std::vector<SceneInventoryElement> elements = fact.elements;
  if (static_cast<int64_t>(elements.size()) > max_elements) {
    elements.resize(static_cast<size_t>(max_elements));
  }
  const std::string route_key = fact.route_key.value_or("");
  record_scene_inventory(turn, scene_inventory_event_data(route_key, elements));
}

}  // namespace engine
}  // namespace tugboat
