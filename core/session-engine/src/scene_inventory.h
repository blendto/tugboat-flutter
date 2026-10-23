// Native scene inventory: the `scene.inventory` fact and shared recording
// for `scene_inventory` events (docs/stateful-engine.md section 4.3).
#ifndef TUGBOAT_SESSION_ENGINE_SCENE_INVENTORY_H
#define TUGBOAT_SESSION_ENGINE_SCENE_INVENTORY_H

#include <optional>
#include <string>
#include <vector>

#include "json.h"
#include "reader.h"

namespace tugboat {
namespace engine {

struct Turn;

struct NormalizedBounds {
  double left = 0;
  double top = 0;
  double width = 0;
  double height = 0;
};

struct SceneInventoryElement {
  std::string fingerprint;
  std::string canonical_path;
  std::optional<std::string> widget_type;
  std::optional<std::string> role;
  std::vector<std::string> actions;
  std::optional<bool> enabled;
  NormalizedBounds bounds_norm;
  std::string tier;
  std::vector<std::string> aliases;
};

// `scene.inventory {routeKey?, elements[]}`.
struct SceneInventoryFact {
  std::optional<std::string> route_key;
  std::optional<std::string> scroll_key;
  std::vector<SceneInventoryElement> elements;
};

bool decode_scene_inventory_fact(const Value& json, const std::string& path,
                                 SceneInventoryFact* out, Error* error);

void apply_scene_inventory(Turn& turn, const SceneInventoryFact& fact);

// Records `scene_inventory` when the dedupe key is new. `data` is the full
// event payload (`inventoryHash`, `routeKey`, `elements`).
void record_scene_inventory(Turn& turn, Value data,
                            const std::string& scroll_key = "");

std::string inventory_hash_for_elements(
    const std::vector<SceneInventoryElement>& elements);

Value scene_inventory_event_data(const std::string& route_key,
                                 const std::vector<SceneInventoryElement>& elements,
                                 const std::string& scroll_key = "");

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_SCENE_INVENTORY_H
