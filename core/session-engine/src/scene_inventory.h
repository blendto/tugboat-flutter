// Native scene inventory: the `scene.inventory` fact and shared recording
// for `scene_inventory` events (docs/stateful-engine.md section 4.3).
#ifndef TUGBOAT_SESSION_ENGINE_SCENE_INVENTORY_H
#define TUGBOAT_SESSION_ENGINE_SCENE_INVENTORY_H

#include <cstdint>
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

// `scene.inventory {routeKey?, elements[], scrollKey?, totalElements?}`.
// `total_elements` is how many elements the adapter found before its own
// cap; C20 reports the larger of it and `elements.size()`.
struct SceneInventoryFact {
  std::optional<std::string> route_key;
  std::optional<std::string> scroll_key;
  std::optional<int64_t> total_elements;
  std::vector<SceneInventoryElement> elements;
};

bool decode_scene_inventory_fact(const Value& json, const std::string& path,
                                 SceneInventoryFact* out, Error* error);

void apply_scene_inventory(Turn& turn, const SceneInventoryFact& fact);

// Records `scene_inventory` with `data` (the full event payload) unless
// `route_key|inventory_hash|scroll_key` was already recorded this session.
// With `truncated_from`, a new key first records the C20
// `capture_diagnostic {component: scene_inventory, truncatedFrom}`; a
// duplicate records nothing.
void record_scene_inventory(Turn& turn, const std::string& route_key,
                            const std::string& inventory_hash,
                            const std::string& scroll_key, Value data,
                            std::optional<int64_t> truncated_from = std::nullopt);


}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_SCENE_INVENTORY_H
