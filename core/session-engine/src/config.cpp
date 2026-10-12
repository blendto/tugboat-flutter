#include "config.h"

#include <string>
#include <utility>
#include <vector>

namespace tugboat {
namespace engine {

namespace {

// Durations are milliseconds in [0, one day]; counts are in [1, 1e6]. The
// bounds keep every derived monotonic deadline far from int64 overflow.
constexpr int64_t kMaxDurationMs = 86400000;
constexpr int64_t kMaxCount = 1000000;

struct IntField {
  const char* key;
  int64_t* out;
  int64_t min;
  int64_t max;
};

// A number in (min_exclusive, max].
struct NumberField {
  const char* key;
  double* out;
  double min_exclusive;
  double max;
};

struct BoolField {
  const char* key;
  bool* out;
};

struct GroupSpec {
  std::vector<IntField> ints;
  std::vector<NumberField> numbers;
  std::vector<BoolField> bools;

  bool knows(const std::string& key) const {
    for (const IntField& f : ints) {
      if (key == f.key) return true;
    }
    for (const NumberField& f : numbers) {
      if (key == f.key) return true;
    }
    for (const BoolField& f : bools) {
      if (key == f.key) return true;
    }
    return false;
  }
};

IntField duration(const char* key, int64_t* out) {
  return IntField{key, out, 0, kMaxDurationMs};
}

IntField count(const char* key, int64_t* out) {
  return IntField{key, out, 1, kMaxCount};
}

bool read_int(const ObjectReader& r, const IntField& field) {
  std::optional<int64_t> value;
  if (!r.opt_int(field.key, &value)) {
    return false;
  }
  if (!value) {
    return true;
  }
  if (*value < field.min || *value > field.max) {
    return r.reject(field.key, "must be in [" + std::to_string(field.min) +
                                   ", " + std::to_string(field.max) + "]");
  }
  *field.out = *value;
  return true;
}

bool read_number(const ObjectReader& r, const NumberField& field) {
  const Value* value = r.get(field.key);
  if (value == nullptr) {
    return true;
  }
  if (!value->is_number()) {
    return r.reject(field.key, "expected number");
  }
  const double number = value->to_double();
  if (number <= field.min_exclusive || number > field.max) {
    return r.reject(field.key, "out of range");
  }
  *field.out = number;
  return true;
}

bool read_bool(const ObjectReader& r, const BoolField& field) {
  std::optional<bool> value;
  if (!r.opt_bool(field.key, &value)) {
    return false;
  }
  if (value) {
    *field.out = *value;
  }
  return true;
}

bool decode_group(const ObjectReader& parent, const char* name,
                  const GroupSpec& spec, Error* error) {
  const Value* json = nullptr;
  if (!parent.opt_object(name, &json)) {
    return false;
  }
  if (json == nullptr) {
    return true;
  }
  const ObjectReader r(*json, parent.child(name), error);
  for (const Member& member : json->members()) {
    if (!spec.knows(member.key)) {
      return invalid(error, r.path() + "." + member.key, "unknown key");
    }
  }
  for (const IntField& field : spec.ints) {
    if (!read_int(r, field)) return false;
  }
  for (const NumberField& field : spec.numbers) {
    if (!read_number(r, field)) return false;
  }
  for (const BoolField& field : spec.bools) {
    if (!read_bool(r, field)) return false;
  }
  return true;
}

GroupSpec limits_spec(LimitsConfig* c) {
  return {{count("maxEvents", &c->max_events),
           count("maxFrames", &c->max_frames),
           count("maxScrollSamples", &c->max_scroll_samples)},
          {},
          {}};
}

GroupSpec gesture_spec(GestureConfig* c) {
  return {{},
          {{"touchSlop", &c->touch_slop, 0, 1e6},
           {"panSlop", &c->pan_slop, 0, 1e6},
           {"scaleSlop", &c->scale_slop, 0, 1e6},
           {"trackpadScaleThreshold", &c->trackpad_scale_threshold, 1, 1e6}},
          {}};
}

GroupSpec interaction_spec(InteractionConfig* c) {
  return {{duration("claimWindowMs", &c->claim_window_ms),
           duration("settleDelayMs", &c->settle_delay_ms),
           count("maxReleased", &c->max_released),
           duration("scrollEndCaptureDelayMs", &c->scroll_end_capture_delay_ms),
           duration("scrollCaptureIntervalMs", &c->scroll_capture_interval_ms),
           duration("factGraceMs", &c->fact_grace_ms)},
          {},
          {{"captureScrollSamples", &c->capture_scroll_samples},
           {"captureScrollScreenshots", &c->capture_scroll_screenshots}}};
}

GroupSpec navigation_spec(NavigationConfig* c) {
  return {{duration("routeBarrierTimeoutMs", &c->route_barrier_timeout_ms),
           count("routeStackLimit", &c->route_stack_limit)},
          {},
          {}};
}

GroupSpec capture_spec(CaptureConfig* c) {
  return {{duration("budgetMs", &c->budget_ms),
           duration("budgetWindowMs", &c->budget_window_ms)},
          {{"degradedScale", &c->degraded_scale, 0, 1}},
          {}};
}

GroupSpec collector_spec(CollectorConfig* c) {
  return {{count("batchSize", &c->batch_size),
           duration("flushIntervalMs", &c->flush_interval_ms),
           count("maxPendingBatches", &c->max_pending_batches),
           count("maxPendingEvents", &c->max_pending_events),
           count("maxPendingFrames", &c->max_pending_frames),
           count("frameChunk", &c->frame_chunk),
           duration("frameTimeoutMs", &c->frame_timeout_ms),
           duration("jsonTimeoutMs", &c->json_timeout_ms),
           duration("identityDebounceMs", &c->identity_debounce_ms),
           duration("backgroundFlushDelayMs", &c->background_flush_delay_ms),
           duration("endDrainTimeoutMs", &c->end_drain_timeout_ms)},
          {},
          {{"enabled", &c->enabled},
           {"reportEventLaneGaps", &c->report_event_lane_gaps}}};
}

GroupSpec capabilities_spec(Capabilities* c) {
  return {{},
          {},
          {{"sceneInventory", &c->scene_inventory},
           {"viewportSemanticMap", &c->viewport_semantic_map},
           {"captureDiagnostics", &c->capture_diagnostics},
           {"actionContext", &c->action_context},
           {"focusChanges", &c->focus_changes},
           {"systemInput", &c->system_input}}};
}

bool decode_host_group(const ObjectReader& r, Config* out, Error* error) {
  const Value* json = nullptr;
  if (!r.opt_object("host", &json)) {
    return false;
  }
  if (json == nullptr) {
    return true;
  }
  Host host;
  if (!decode_host(*json, r.child("host"), &host, error)) {
    return false;
  }
  out->host = std::move(host);
  return true;
}

}  // namespace

bool decode_config(const Value& input, const std::string& path, Config* out,
                   Error* error) {
  const ObjectReader r(input, path, error);
  Config config;
  if (!r.check_keys({"host", "limits", "gesture", "interaction", "navigation",
                     "capture", "collector", "capabilities"}) ||
      !decode_host_group(r, &config, error) ||
      !decode_group(r, "limits", limits_spec(&config.limits), error) ||
      !decode_group(r, "gesture", gesture_spec(&config.gesture), error) ||
      !decode_group(r, "interaction", interaction_spec(&config.interaction),
                    error) ||
      !decode_group(r, "navigation", navigation_spec(&config.navigation),
                    error) ||
      !decode_group(r, "capture", capture_spec(&config.capture), error) ||
      !decode_group(r, "collector", collector_spec(&config.collector),
                    error) ||
      !decode_group(r, "capabilities",
                    capabilities_spec(&config.capabilities), error)) {
    return false;
  }
  *out = std::move(config);
  return true;
}

}  // namespace engine
}  // namespace tugboat
