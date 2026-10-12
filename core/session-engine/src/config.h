// `engine.configure` (docs/stateful-engine.md section 6): the typed engine
// configuration with Dart's defaults. Every group is validated now so later
// phases plug in; phase 3a acts on `host` and `limits.maxEvents` only.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CONFIG_H
#define TUGBOAT_SESSION_ENGINE_CONFIG_H

#include <cstdint>
#include <optional>
#include <string>

#include "host.h"
#include "json.h"
#include "reader.h"

namespace tugboat {
namespace engine {

struct LimitsConfig {
  int64_t max_events = 5000;
  int64_t max_frames = 500;
  int64_t max_scroll_samples = 200;
};

// Toolkit gesture thresholds; the defaults are Flutter's.
struct GestureConfig {
  double touch_slop = 18;
  double pan_slop = 36;
  double scale_slop = 18;
  double trackpad_scale_threshold = 1.08;
};

struct InteractionConfig {
  int64_t claim_window_ms = 1250;
  int64_t settle_delay_ms = 1000;
  int64_t max_released = 8;
  int64_t scroll_end_capture_delay_ms = 0;
  bool capture_scroll_samples = false;
  // Low-priority `scroll` captures while scrolling (Dart
  // `captureScrollScreenshots`).
  bool capture_scroll_screenshots = false;
  int64_t scroll_capture_interval_ms = 2000;
  int64_t fact_grace_ms = 0;
};

struct NavigationConfig {
  int64_t route_barrier_timeout_ms = 5000;
  int64_t route_stack_limit = 16;
};

struct CaptureConfig {
  int64_t budget_ms = 60;
  int64_t budget_window_ms = 5000;
  double degraded_scale = 0.8;
};

struct CollectorConfig {
  bool enabled = false;
  int64_t batch_size = 10;
  int64_t flush_interval_ms = 3000;
  int64_t max_pending_batches = 20;
  int64_t max_pending_events = 60;
  int64_t max_pending_frames = 20;
  int64_t frame_chunk = 20;
  int64_t frame_timeout_ms = 15000;
  int64_t json_timeout_ms = 15000;      // change C3
  int64_t identity_debounce_ms = 3000;
  int64_t background_flush_delay_ms = 500;
  int64_t end_drain_timeout_ms = 5000;  // change C5
  bool report_event_lane_gaps = false;  // change C6
};

// TugboatReplayConfig evidence switches.
struct Capabilities {
  bool scene_inventory = false;
  bool viewport_semantic_map = false;
  bool capture_diagnostics = false;
  bool action_context = false;
  bool focus_changes = false;
  bool system_input = false;
};

struct Config {
  std::optional<Host> host;
  LimitsConfig limits;
  GestureConfig gesture;
  InteractionConfig interaction;
  NavigationConfig navigation;
  CaptureConfig capture;
  CollectorConfig collector;
  Capabilities capabilities;
};

// Decodes an `engine.configure` input at JSON path `path`. Every group and
// field is optional; absent ones take Dart's defaults. A configure message
// replaces the whole configuration.
bool decode_config(const Value& input, const std::string& path, Config* out,
                   Error* error);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CONFIG_H
