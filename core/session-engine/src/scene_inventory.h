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
  // Share (0 to 1) of the paint box inside the boundary and not clipped.
  // Absent when fully visible or unknown. Never hash input.
  std::optional<double> visible_fraction;
  // The id of the nearest explicit tag above the element. Never hash input.
  std::optional<std::string> tag;
  // The canonical path runs through a structural list position (`[item:N]`):
  // the fingerprint names a position, not the control. Sent by the adapter
  // (true only); never hash input.
  bool positional = false;
};

// `surface {kind, widgetClass?}`: what kind of surface an inventory
// describes. `kind` is one of page, sheet, dialog, popup, menu.
struct InventorySurface {
  std::string kind;
  std::optional<std::string> widget_class;
};

// `viewport`: the frame `boundsNorm` is measured in (logical pixels).
struct InventoryViewport {
  double width_px = 0;
  double height_px = 0;
  double device_pixel_ratio = 1;
  double boundary_left = 0;
  double boundary_top = 0;
  double inset_top = 0;
  double inset_bottom = 0;
  double inset_left = 0;
  double inset_right = 0;
  double keyboard_inset = 0;
};

// `scroll`: the primary vertical scrollable's position (logical pixels).
struct InventoryScroll {
  double offset_px = 0;
  std::optional<double> max_extent_px;
};

// `scene.inventory {routeKey?, elements[], scrollKey?, totalElements?}`.
// `total_elements` is how many elements the adapter found before its own
// cap; C20 reports the larger of it and `elements.size()`.
//
// Exploration metadata, the same as Flutter's `scene_inventory` (0.11.0):
// `trigger` (initial, resume, route, tap, scroll, gesture, settled, manual),
// `surface`, `viewport`, `scroll`, and per element `visibleFraction` and
// `tag`. None of it is hash input, and each is emitted only when sent.
// `positional` is sent by the adapter (path through `[item:N]`). `resample` marks the
// answer to a `scene.sample` effect (section 4.3.2); the engine stamps its
// `trigger` itself.
struct SceneInventoryFact {
  bool resample = false;
  std::optional<std::string> trigger;
  std::optional<InventorySurface> surface;
  std::optional<InventoryViewport> viewport;
  std::optional<InventoryScroll> scroll;
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
// Returns whether it recorded; `force` records a re-sample whose key is known.
bool record_scene_inventory(Turn& turn, const std::string& route_key,
                            const std::string& inventory_hash,
                            const std::string& scroll_key, Value data,
                            std::optional<int64_t> truncated_from = std::nullopt,
                            bool force = false);


}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_SCENE_INVENTORY_H
