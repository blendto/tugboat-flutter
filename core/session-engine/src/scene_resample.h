// The settled re-sample of native scene inventories (docs/stateful-engine.md
// section 4.3.2): what one route visit has sent (novelty), and the watch that
// decides when to ask the host for another inventory. The same rules as
// Flutter's `InventoryVisit` and `SettledInventoryWatch` (0.11.0).
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_SCENE_RESAMPLE_H
#define TUGBOAT_SESSION_ENGINE_SCENE_RESAMPLE_H

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "clock.h"
#include "output.h"
#include "turn.h"

namespace tugboat {
namespace engine {

struct EngineState;
struct SceneInventoryElement;

// Quiet window after the last drawn frame before a re-sample (ms).
constexpr int64_t kSettledDebounceMs = 400;
// Continuous frame activity after which a sample is taken anyway (ms).
constexpr int64_t kSettledMaxBusyMs = 2000;
// Longest window between samples (ms).
constexpr int64_t kSettledMaxWindowMs = 6400;
// Backstop: re-sampled inventories emitted per route visit.
constexpr int kResampleCapPerVisit = 50;
// Grid step of the coarse bounds signature a `scroll` inventory is compared by.
constexpr double kSettledGridStep = 0.02;

constexpr const char* kSceneWindowTimer = "scene.window";

// What one route visit (route epoch) has sent: each element's novelty path
// with the enabled states it was sent in.
struct InventoryVisit {
  int64_t route_epoch = 0;
  std::map<std::string, std::set<std::string>> sent;
  int resamples = 0;
  // `trigger` of the next re-sample: the moment that asked for it, else
  // `settled`. Used once.
  std::string pending_trigger = "settled";

  bool cap_reached() const { return resamples >= kResampleCapPerVisit; }
};

struct SceneResampleState {
  std::optional<InventoryVisit> visit;
  // The watch, for `watch_epoch`'s visit.
  bool watch_active = false;
  int64_t watch_epoch = 0;
  bool window_open = false;
  bool framed_in_window = false;
  int64_t window_ms = kSettledDebounceMs;
  int64_t busy_ms = 0;
  // A sample was asked and its answer has not come.
  bool awaiting_sample = false;
  // Contents emitted this session (`key|hash of states`), and the signature
  // of the last inventory sent (positional `scroll` repeats).
  std::set<std::string> sent_contents;
  std::optional<std::string> last_signature;
};

// Every list position `[item:N]` collapsed to `[item]`, except a
// `PageView`'s own page position.
std::string inventory_novelty_path(const std::string& canonical_path);

// True when the re-sample is on: native scene inventory and the
// `resampleSettledInventory` switch.
bool resample_enabled(const EngineState& state);

// Records `elements` as sent in the current visit; a tap, gesture or scroll
// `trigger` labels the next re-sample; then arms the watch (or nudges it back
// to the shortest window).
void note_visit_sent(Turn& turn,
                     const std::vector<SceneInventoryElement>& elements);
void note_inventory_sent(Turn& turn,
                         const std::vector<SceneInventoryElement>& elements,
                         const std::string& trigger);

// Arms the watch for an inventory that found nothing to list yet.
void arm_resample_watch(Turn& turn);

// An answer to `scene.sample`. Returns true when it is new to the visit.
bool is_novel_for_visit(Turn& turn,
                        const std::vector<SceneInventoryElement>& elements);
InventoryVisit& current_visit(EngineState* state);

// `scene.frame`: a frame was drawn while the watch is armed.
void on_scene_frame(Turn& turn);
// The `scene.window` timer.
void on_scene_window(Turn& turn);
// Stops the watch (route change, background, session end, cap reached).
void stop_resample_watch(EngineState* state, Output* out);
// The sample found something new: back to the shortest window.
void resample_emitted(EngineState* state);
void reset_resample(EngineState* state);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_SCENE_RESAMPLE_H
