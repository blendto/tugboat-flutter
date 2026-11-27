#include "scene_inventory.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "engine_state.h"
#include "evidence.h"
#include "recorder.h"
#include "scene_resample.h"
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

bool opt_number(const ObjectReader& r, const char* key,
                std::optional<double>* out) {
  out->reset();
  const Value* value = r.get(key);
  if (value == nullptr) return true;
  if (!value->is_number()) return r.reject(key, "expected number");
  *out = value->to_double();
  return true;
}

bool req_non_negative(const ObjectReader& r, const char* key, double* out) {
  if (!r.req_double(key, out)) return false;
  if (!(*out >= 0)) return r.reject(key, "must not be negative");
  return true;
}

bool decode_surface(const ObjectReader& parent, const Value& json,
                    InventorySurface* out, Error* error) {
  const ObjectReader r(json, parent.child("surface"), error);
  if (!r.check_keys({"kind", "widgetClass"}) ||
      !r.req_string("kind", &out->kind) ||
      !r.opt_string("widgetClass", &out->widget_class)) {
    return false;
  }
  if (out->kind != "page" && out->kind != "sheet" && out->kind != "dialog" &&
      out->kind != "popup" && out->kind != "menu") {
    return r.reject("kind", "expected page, sheet, dialog, popup or menu");
  }
  return true;
}

bool decode_viewport(const ObjectReader& parent, const Value& json,
                     InventoryViewport* out, Error* error) {
  const ObjectReader r(json, parent.child("viewport"), error);
  const Value* offset = nullptr;
  const Value* insets = nullptr;
  if (!r.check_keys({"widthPx", "heightPx", "devicePixelRatio",
                     "boundaryOffset", "insets", "keyboardInset"}) ||
      !req_non_negative(r, "widthPx", &out->width_px) ||
      !req_non_negative(r, "heightPx", &out->height_px) ||
      !req_non_negative(r, "devicePixelRatio", &out->device_pixel_ratio) ||
      !(out->device_pixel_ratio > 0 ||
        r.reject("devicePixelRatio", "must be positive")) ||
      !r.req_object("boundaryOffset", &offset) ||
      !r.req_object("insets", &insets) ||
      !req_non_negative(r, "keyboardInset", &out->keyboard_inset)) {
    return false;
  }
  const ObjectReader o(*offset, r.child("boundaryOffset"), error);
  if (!o.check_keys({"left", "top"}) ||
      !o.req_double("left", &out->boundary_left) ||
      !o.req_double("top", &out->boundary_top)) {
    return false;
  }
  const ObjectReader i(*insets, r.child("insets"), error);
  return i.check_keys({"top", "bottom", "left", "right"}) &&
         req_non_negative(i, "top", &out->inset_top) &&
         req_non_negative(i, "bottom", &out->inset_bottom) &&
         req_non_negative(i, "left", &out->inset_left) &&
         req_non_negative(i, "right", &out->inset_right);
}

bool decode_scroll(const ObjectReader& parent, const Value& json,
                   InventoryScroll* out, Error* error) {
  const ObjectReader r(json, parent.child("scroll"), error);
  return r.check_keys({"offsetPx", "maxExtentPx"}) &&
         r.req_double("offsetPx", &out->offset_px) &&
         opt_number(r, "maxExtentPx", &out->max_extent_px);
}

bool valid_trigger(const std::string& trigger) {
  return trigger == "initial" || trigger == "resume" || trigger == "route" ||
         trigger == "tap" || trigger == "scroll" || trigger == "gesture" ||
         trigger == "settled" || trigger == "manual";
}

bool decode_positional(const ObjectReader& r, SceneInventoryElement* out) {
  std::optional<bool> positional;
  if (!r.opt_bool("positional", &positional)) return false;
  out->positional = positional.value_or(false);
  return true;
}

bool decode_element(const Value& json, const std::string& path,
                    SceneInventoryElement* out, Error* error) {
  const ObjectReader r(json, path, error);
  std::string tier;
  if (!r.check_keys({"fingerprint", "canonicalPath", "widgetType", "role",
                     "actions", "enabled", "boundsNorm", "tier", "aliases",
                     "visibleFraction", "tag", "positional"}) ||
      !r.req_string("fingerprint", &out->fingerprint) ||
      !r.req_string("canonicalPath", &out->canonical_path) ||
      !r.opt_string("widgetType", &out->widget_type) ||
      !r.opt_string("role", &out->role) ||
      !decode_string_array(r, "actions", &out->actions, error) ||
      !r.opt_bool("enabled", &out->enabled) || !decode_bounds(r, &out->bounds_norm, error) ||
      !r.req_string("tier", &tier) ||
      !decode_string_array(r, "aliases", &out->aliases, error) ||
      !opt_number(r, "visibleFraction", &out->visible_fraction) ||
      !r.opt_string("tag", &out->tag) || !decode_positional(r, out)) {
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
  if (out->visible_fraction &&
      (!(*out->visible_fraction >= 0) || *out->visible_fraction > 1)) {
    return r.reject("visibleFraction", "out of range");
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
  if (element->tag) {
    *element->tag = bound_string(*element->tag);
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
  if (element.visible_fraction) {
    json.set("visibleFraction", Value::number(*element.visible_fraction));
  }
  if (element.tag) {
    json.set("tag", Value::string(*element.tag));
  }
  // Derived from the path (the `[item:N]` rule the novelty paths use), or
  // sent by the adapter: either one marks it.
  if (element.positional ||
      element.canonical_path.find("[item:") != std::string::npos) {
    json.set("positional", Value::boolean(true));
  }
  return json;
}

Value surface_json(const InventorySurface& surface) {
  Value json = Value::object();
  json.set("kind", Value::string(surface.kind));
  if (surface.widget_class) {
    json.set("widgetClass", Value::string(bound_string(*surface.widget_class)));
  }
  return json;
}

Value viewport_json(const InventoryViewport& viewport) {
  Value insets = Value::object();
  insets.set("top", Value::number(viewport.inset_top));
  insets.set("bottom", Value::number(viewport.inset_bottom));
  insets.set("left", Value::number(viewport.inset_left));
  insets.set("right", Value::number(viewport.inset_right));
  Value offset = Value::object();
  offset.set("left", Value::number(viewport.boundary_left));
  offset.set("top", Value::number(viewport.boundary_top));
  Value json = Value::object();
  json.set("widthPx", Value::number(viewport.width_px));
  json.set("heightPx", Value::number(viewport.height_px));
  json.set("devicePixelRatio", Value::number(viewport.device_pixel_ratio));
  json.set("boundaryOffset", std::move(offset));
  json.set("insets", std::move(insets));
  json.set("keyboardInset", Value::number(viewport.keyboard_inset));
  json.set("referenceFrame", Value::string("captureBoundary"));
  return json;
}

Value scroll_json(const InventoryScroll& scroll) {
  Value json = Value::object();
  json.set("offsetPx", Value::number(scroll.offset_px));
  if (scroll.max_extent_px) {
    json.set("maxExtentPx", Value::number(*scroll.max_extent_px));
  }
  json.set("axis", Value::string("vertical"));
  return json;
}

std::string dedupe_key(const std::string& route_key,
                       const std::string& inventory_hash,
                       const std::string& scroll_key) {
  return route_key + "|" + inventory_hash + "|" + scroll_key;
}

// `fingerprint:enabled` of every element, sorted: what an exact repeat is
// compared by (Flutter `_inventoryContentKey`).
std::string content_key(const std::string& dedupe,
                        const std::vector<SceneInventoryElement>& elements) {
  std::vector<std::string> states;
  states.reserve(elements.size());
  for (const SceneInventoryElement& element : elements) {
    states.push_back(element.fingerprint + ":" +
                     (!element.enabled ? "null"
                                       : (*element.enabled ? "true" : "false")));
  }
  std::sort(states.begin(), states.end());
  std::string out = dedupe + "|";
  for (const std::string& state : states) out += state + ";";
  return out;
}

// routeKey, hash, count and the boxes on a 2% grid: a `scroll` inventory is
// positional, so it is sent only when its content moved.
std::string signature_of(const std::string& route_key, const std::string& hash,
                         const std::vector<SceneInventoryElement>& elements) {
  auto q = [](double value) {
    return std::to_string(
        static_cast<int64_t>(std::llround(value / kSettledGridStep)));
  };
  std::vector<std::string> boxes;
  boxes.reserve(elements.size());
  for (const SceneInventoryElement& element : elements) {
    const NormalizedBounds& b = element.bounds_norm;
    boxes.push_back(q(b.left) + "," + q(b.top) + "," + q(b.width) + "," +
                    q(b.height));
  }
  std::sort(boxes.begin(), boxes.end());
  std::string out = route_key + "|" + hash + "|" +
                    std::to_string(elements.size()) + "|";
  for (const std::string& box : boxes) out += box + ";";
  return out;
}

}  // namespace

bool decode_scene_inventory_fact(const Value& json, const std::string& path,
                                 SceneInventoryFact* out, Error* error) {
  const ObjectReader r(json, path, error);
  const Value* elements = nullptr;
  const Value* surface = nullptr;
  const Value* viewport = nullptr;
  const Value* scroll = nullptr;
  std::optional<bool> resample;
  if (!r.check_keys({"routeKey", "elements", "scrollKey", "totalElements",
                     "resample", "trigger", "surface", "viewport",
                     "scroll"}) ||
      !r.opt_string("routeKey", &out->route_key) ||
      !r.opt_string("scrollKey", &out->scroll_key) ||
      !r.opt_int("totalElements", &out->total_elements) ||
      !r.opt_bool("resample", &resample) ||
      !r.opt_string("trigger", &out->trigger) ||
      !r.opt_object("surface", &surface) ||
      !r.opt_object("viewport", &viewport) ||
      !r.opt_object("scroll", &scroll) ||
      !r.req_array("elements", &elements)) {
    return false;
  }
  out->resample = resample.value_or(false);
  if (out->trigger && !valid_trigger(*out->trigger)) {
    return r.reject("trigger", "expected an inventory trigger");
  }
  if (surface != nullptr) {
    InventorySurface value;
    if (!decode_surface(r, *surface, &value, error)) return false;
    out->surface = std::move(value);
  }
  if (viewport != nullptr) {
    InventoryViewport value;
    if (!decode_viewport(r, *viewport, &value, error)) return false;
    out->viewport = value;
  }
  if (scroll != nullptr) {
    InventoryScroll value;
    if (!decode_scroll(r, *scroll, &value, error)) return false;
    out->scroll = value;
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

bool record_scene_inventory(Turn& turn, const std::string& route_key,
                            const std::string& inventory_hash,
                            const std::string& scroll_key, Value data,
                            std::optional<int64_t> truncated_from,
                            bool force) {
  EngineState& state = *turn.state;
  const std::string key = dedupe_key(route_key, inventory_hash, scroll_key);
  // A re-sample that flips a state keeps the fingerprints, so its key is
  // already known; it is recorded once per state (`force`).
  if (!state.interactions.emitted_inventories.insert(key).second && !force) {
    return false;
  }
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
  return true;
}

void apply_scene_inventory(Turn& turn, const SceneInventoryFact& fact) {
  EngineState& state = *turn.state;
  if (!state.config.capabilities.native_scene_inventory) {
    return;
  }
  const bool resample_on = resample_enabled(state);
  // An answer to `scene.sample` is taken only while one is asked for: a late
  // answer (after a route change, a pause or a newer watch) or an unsolicited
  // one is dropped.
  if (fact.resample && (!resample_on || !state.scene_resample.watch_active ||
                        !state.scene_resample.awaiting_sample)) {
    return;
  }
  if (fact.resample) state.scene_resample.awaiting_sample = false;
  if (fact.elements.empty()) {
    // A page with nothing to list yet (a full-screen spinner) is still
    // watched, so its content is sampled once it loads.
    if (resample_on && !fact.resample) arm_resample_watch(turn);
    return;
  }
  // C20: keep the first `maxSceneInventoryElements`; the diagnostic reports
  // what the adapter found (`totalElements`) or sent, whichever is larger.
  const size_t limit = static_cast<size_t>(
      state.config.limits.max_scene_inventory_elements);
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
  SceneResampleState& resample = state.scene_resample;

  // The label: the moment that asked for a re-sample, else the adapter's.
  std::optional<std::string> trigger = fact.trigger;
  if (fact.resample) {
    InventoryVisit& visit = current_visit(&state);
    trigger = visit.pending_trigger;
    visit.pending_trigger = "settled";
    if (!is_novel_for_visit(turn, elements)) return;
    if (visit.cap_reached()) {
      stop_resample_watch(&state, turn.out);
      return;
    }
    note_visit_sent(turn, elements);
    // A state flip keeps the fingerprints, so only an exact repeat is held
    // back (it is also counted as sent above).
    const std::string content =
        content_key(dedupe_key(route_key, hash, ""), elements);
    if (resample.sent_contents.count(content) != 0) return;
  }

  Value data = Value::object();
  data.set("inventoryHash", Value::string(hash));
  data.set("routeKey", Value::string(route_key));
  if (fact.surface) data.set("surface", surface_json(*fact.surface));
  if (trigger) data.set("trigger", Value::string(*trigger));
  if (fact.viewport) data.set("viewport", viewport_json(*fact.viewport));
  if (fact.scroll) data.set("scroll", scroll_json(*fact.scroll));
  data.set("elements", std::move(elements_json));
  if (!scroll_key.empty()) {
    data.set("scrollKey", Value::string(scroll_key));
  }

  const std::string signature = signature_of(route_key, hash, elements);
  // Only an inventory a capture builds is positional; a re-sample is always
  // sent (Flutter `_emitResampleIfNovel`), so a state flip found after a
  // scroll is not lost.
  const bool positional_repeat = !fact.resample && trigger &&
                                 *trigger == "scroll" &&
                                 resample.last_signature == signature;
  bool emitted = false;
  if (!positional_repeat) {
    emitted = record_scene_inventory(turn, route_key, hash, scroll_key,
                                     std::move(data), truncated_from,
                                     fact.resample);
  }
  if (emitted) {
    resample.last_signature = signature;
    // Flutter's content key always has an empty scroll context.
    resample.sent_contents.insert(
        content_key(dedupe_key(route_key, hash, ""), elements));
  }
  if (!resample_on) return;
  if (fact.resample) {
    if (!emitted) return;
    InventoryVisit& visit = current_visit(&state);
    visit.resamples++;
    resample_emitted(&state);
    if (visit.cap_reached()) stop_resample_watch(&state, turn.out);
  } else {
    note_inventory_sent(turn, elements, trigger.value_or(""));
  }
}

}  // namespace engine
}  // namespace tugboat
