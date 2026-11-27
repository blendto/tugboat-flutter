#include "scene_resample.h"

#include <algorithm>

#include "engine_state.h"
#include "scene_inventory.h"

namespace tugboat {
namespace engine {

namespace {

bool is_item_token(const std::string& segment) {
  return segment.size() >= 8 && segment.compare(0, 6, "[item:") == 0 &&
         segment.back() == ']' &&
         segment.find(']') == segment.size() - 1;
}

bool starts_with(const std::string& value, const char* prefix) {
  return value.rfind(prefix, 0) == 0;
}

enum class Paging { kNone, kPageView, kInPage };

Paging next_paging(Paging paging, const std::string& segment) {
  if (starts_with(segment, "PageView#")) return Paging::kPageView;
  if (!starts_with(segment, "Scrollable#")) return paging;
  return paging == Paging::kPageView ? Paging::kInPage : Paging::kNone;
}

std::string state_of(const SceneInventoryElement& element) {
  if (!element.enabled) return "null";
  return *element.enabled ? "true" : "false";
}

bool can_run(const EngineState& state) {
  return state.session.has_value() &&
         state.lifecycle == LifecycleState::kActive && resample_enabled(state);
}

void open_window(Turn& turn, SceneResampleState* resample) {
  resample->window_open = true;
  resample->framed_in_window = false;
  turn.state->timers.schedule(kSceneWindowTimer,
                              turn.at.mono_us + resample->window_ms * 1000,
                              turn.out);
}

void start_watch(Turn& turn) {
  SceneResampleState& resample = turn.state->scene_resample;
  stop_resample_watch(turn.state, turn.out);
  resample.watch_active = true;
  resample.watch_epoch = turn.state->navigation.route_epoch;
  resample.window_open = false;
  resample.framed_in_window = false;
  resample.window_ms = kSettledDebounceMs;
  resample.busy_ms = 0;
  resample.awaiting_sample = false;
  turn.out->effects.push_back(SceneWatch{true});
}

void arm_watch(Turn& turn) {
  EngineState* state = turn.state;
  if (!can_run(*state) || current_visit(state).cap_reached()) return;
  SceneResampleState& resample = state->scene_resample;
  if (resample.watch_active &&
      resample.watch_epoch == state->navigation.route_epoch) {
    resample.window_ms = kSettledDebounceMs;
    return;
  }
  start_watch(turn);
}

void sample(Turn& turn) {
  SceneResampleState& resample = turn.state->scene_resample;
  resample.busy_ms = 0;
  resample.awaiting_sample = true;
  // A sample that finds nothing new doubles the window; the answer resets it
  // when the sample is emitted.
  resample.window_ms = std::min(resample.window_ms * 2, kSettledMaxWindowMs);
  turn.out->effects.push_back(SceneSample{});
}

}  // namespace

std::string inventory_novelty_path(const std::string& canonical_path) {
  std::string out;
  Paging paging = Paging::kNone;
  size_t start = 0;
  while (true) {
    const size_t slash = canonical_path.find('/', start);
    const std::string segment = canonical_path.substr(
        start, slash == std::string::npos ? std::string::npos : slash - start);
    paging = next_paging(paging, segment);
    const bool collapse = paging != Paging::kInPage && is_item_token(segment);
    if (start > 0) out += '/';
    out += collapse ? "[item]" : segment;
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  return out;
}

bool resample_enabled(const EngineState& state) {
  return state.config.capabilities.native_scene_inventory &&
         state.config.capabilities.resample_settled_inventory;
}

InventoryVisit& current_visit(EngineState* state) {
  SceneResampleState& resample = state->scene_resample;
  const int64_t epoch = state->navigation.route_epoch;
  if (!resample.visit || resample.visit->route_epoch != epoch) {
    resample.visit = InventoryVisit{};
    resample.visit->route_epoch = epoch;
  }
  return *resample.visit;
}

bool is_novel_for_visit(Turn& turn,
                        const std::vector<SceneInventoryElement>& elements) {
  const InventoryVisit& visit = current_visit(turn.state);
  for (const SceneInventoryElement& element : elements) {
    const auto found = visit.sent.find(inventory_novelty_path(element.canonical_path));
    if (found == visit.sent.end() || found->second.count(state_of(element)) == 0) {
      return true;
    }
  }
  return false;
}

void note_visit_sent(Turn& turn,
                     const std::vector<SceneInventoryElement>& elements) {
  InventoryVisit& visit = current_visit(turn.state);
  for (const SceneInventoryElement& element : elements) {
    visit.sent[inventory_novelty_path(element.canonical_path)].insert(
        state_of(element));
  }
}

void note_inventory_sent(Turn& turn,
                         const std::vector<SceneInventoryElement>& elements,
                         const std::string& trigger) {
  note_visit_sent(turn, elements);
  InventoryVisit& visit = current_visit(turn.state);
  if (trigger == "tap" || trigger == "gesture" || trigger == "scroll") {
    visit.pending_trigger = trigger;
  }
  arm_watch(turn);
}

void arm_resample_watch(Turn& turn) { arm_watch(turn); }

void on_scene_frame(Turn& turn) {
  EngineState* state = turn.state;
  SceneResampleState& resample = state->scene_resample;
  if (!resample.watch_active) return;
  if (!can_run(*state) || resample.watch_epoch != state->navigation.route_epoch) {
    stop_resample_watch(state, turn.out);
    return;
  }
  if (!resample.window_open) {
    resample.busy_ms = 0;
    open_window(turn, &resample);
  } else {
    resample.framed_in_window = true;
  }
}

void on_scene_window(Turn& turn) {
  EngineState* state = turn.state;
  SceneResampleState& resample = state->scene_resample;
  resample.window_open = false;
  if (!resample.watch_active) return;
  if (!can_run(*state) || resample.watch_epoch != state->navigation.route_epoch) {
    stop_resample_watch(state, turn.out);
    return;
  }
  if (resample.framed_in_window) {
    resample.busy_ms += resample.window_ms;
    if (resample.busy_ms < kSettledMaxBusyMs) {
      open_window(turn, &resample);
      return;
    }
  }
  sample(turn);
}

void stop_resample_watch(EngineState* state, Output* out) {
  SceneResampleState& resample = state->scene_resample;
  if (!resample.watch_active) return;
  resample.watch_active = false;
  resample.window_open = false;
  resample.awaiting_sample = false;
  state->timers.cancel(kSceneWindowTimer, out);
  out->effects.push_back(SceneWatch{false});
}

void resample_emitted(EngineState* state) {
  state->scene_resample.window_ms = kSettledDebounceMs;
}

void reset_resample(EngineState* state) {
  state->scene_resample = SceneResampleState{};
}

}  // namespace engine
}  // namespace tugboat
