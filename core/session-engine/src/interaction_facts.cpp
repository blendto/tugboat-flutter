#include "interaction_facts.h"

#include <initializer_list>
#include <utility>

#include "name_table.h"

namespace tugboat {
namespace engine {

namespace {

enum class PointerDevice { kTouch, kMouse, kStylus, kTrackpad };

constexpr NamedValue<PointerPhase> kPointerPhases[] = {
    {"down", PointerPhase::kDown},
    {"move", PointerPhase::kMove},
    {"up", PointerPhase::kUp},
    {"cancel", PointerPhase::kCancel},
};

constexpr NamedValue<PointerDevice> kPointerDevices[] = {
    {"touch", PointerDevice::kTouch},
    {"mouse", PointerDevice::kMouse},
    {"stylus", PointerDevice::kStylus},
    {"trackpad", PointerDevice::kTrackpad},
};

constexpr NamedValue<PanZoomPhase> kPanZoomPhases[] = {
    {"start", PanZoomPhase::kStart},
    {"update", PanZoomPhase::kUpdate},
    {"end", PanZoomPhase::kEnd},
};

constexpr NamedValue<ScrollPhase> kScrollPhases[] = {
    {"start", ScrollPhase::kStart},
    {"update", ScrollPhase::kUpdate},
    {"end", ScrollPhase::kEnd},
    {"overscroll", ScrollPhase::kOverscroll},
};

// Dart `Axis.name`.
constexpr NamedValue<ScrollAxis> kScrollAxes[] = {
    {"vertical", ScrollAxis::kVertical},
    {"horizontal", ScrollAxis::kHorizontal},
};

constexpr NamedValue<FocusKind> kFocusKinds[] = {
    {"text_input", FocusKind::kTextInput},
    {"other", FocusKind::kOther},
    {"none", FocusKind::kNone},
};

constexpr NamedValue<SystemInput> kSystemInputs[] = {
    {"back", SystemInput::kBack},
    {"volume_up", SystemInput::kVolumeUp},
    {"volume_down", SystemInput::kVolumeDown},
    {"volume_mute", SystemInput::kVolumeMute},
    {"power", SystemInput::kPower},
    {"media_play_pause", SystemInput::kMediaPlayPause},
};

constexpr NamedValue<CaptureResultOutcome> kCaptureOutcomes[] = {
    {"captured", CaptureResultOutcome::kCaptured},
    {"paintUnchanged", CaptureResultOutcome::kPaintUnchanged},
    {"failed", CaptureResultOutcome::kFailed},
    {"cancelled", CaptureResultOutcome::kCancelled},
};

bool read_point(const ObjectReader& r, const char* x_key, const char* y_key,
                Point* out) {
  return r.req_double(x_key, &out->x) && r.req_double(y_key, &out->y);
}

bool read_non_empty(const ObjectReader& r, const char* key, std::string* out) {
  if (!r.req_string(key, out)) return false;
  return !out->empty() || r.reject(key, "must not be empty");
}

bool read_non_negative(const ObjectReader& r, const char* key, int64_t* out) {
  if (!r.req_int(key, out)) return false;
  return *out >= 0 || r.reject(key, "must not be negative");
}

// Fails when any of `keys` is present: `why` says which phase allows it.
bool reject_present(const ObjectReader& r,
                    std::initializer_list<const char*> keys, const char* why) {
  for (const char* key : keys) {
    if (r.get(key) != nullptr) return r.reject(key, why);
  }
  return true;
}

bool decode_tap_field(const ObjectReader& r, PointerFact* out, Error* error) {
  const Value* tap = nullptr;
  if (!r.opt_object("tap", &tap)) return false;
  if (tap == nullptr) return true;
  if (out->phase != PointerPhase::kDown && out->phase != PointerPhase::kUp) {
    return r.reject("tap", "only allowed on down or up");
  }
  TapEvidence evidence;
  if (!decode_tap_evidence(*tap, r.child("tap"), &evidence, error)) {
    return false;
  }
  out->tap = std::move(evidence);
  return true;
}

bool decode_boundary(const ObjectReader& r, CapturedFrame* frame,
                     Error* error) {
  const Value* json = nullptr;
  if (!r.opt_object("boundaryRect", &json)) return false;
  if (json == nullptr) return true;
  const ObjectReader b(*json, r.child("boundaryRect"), error);
  BoundaryRect rect;
  if (!b.check_keys({"x", "y", "width", "height"}) ||
      !b.req_double("x", &rect.x) || !b.req_double("y", &rect.y) ||
      !b.req_double("width", &rect.width) ||
      !b.req_double("height", &rect.height)) {
    return false;
  }
  frame->boundary = rect;
  return true;
}

// TugboatScreenshotCaptureBackend: a closed vocabulary on the collector
// wire (`frameMetadata[].requestedBackend` / `resolvedBackend`).
bool check_backend(const ObjectReader& r, const char* key,
                   const OptString& value) {
  if (!value || *value == "flutterRepaintBoundary" ||
      *value == "nativeCpuExperimental") {
    return true;
  }
  return r.reject(key,
                  "expected flutterRepaintBoundary or nativeCpuExperimental");
}

bool decode_frame(const Value& json, const std::string& path,
                  CapturedFrame* out, Error* error) {
  const ObjectReader r(json, path, error);
  std::optional<bool> masked;
  if (!r.check_keys({"handle", "width", "height", "contentHash", "masked",
                     "byteLength", "captureMicros", "requestedBackend",
                     "resolvedBackend", "fallbackReason"}) ||
      !read_non_empty(r, "handle", &out->handle) ||
      !read_non_negative(r, "width", &out->width) ||
      !read_non_negative(r, "height", &out->height) ||
      !r.req_string("contentHash", &out->content_hash) ||
      !r.opt_bool("masked", &masked) ||
      !read_non_negative(r, "byteLength", &out->byte_length) ||
      !read_non_negative(r, "captureMicros", &out->capture_micros) ||
      !r.opt_string("requestedBackend", &out->requested_backend) ||
      !r.opt_string("resolvedBackend", &out->resolved_backend) ||
      !r.opt_string("fallbackReason", &out->fallback_reason) ||
      !check_backend(r, "requestedBackend", out->requested_backend) ||
      !check_backend(r, "resolvedBackend", out->resolved_backend)) {
    return false;
  }
  if (!masked) return r.reject("masked", "required");
  out->masked = *masked;
  return true;
}

}  // namespace

const char* focus_kind_name(FocusKind kind) {
  return name_of(kFocusKinds, kind);
}

const char* scroll_axis_name(ScrollAxis axis) {
  return name_of(kScrollAxes, axis);
}

const char* system_input_name(SystemInput input) {
  return name_of(kSystemInputs, input);
}

bool decode_pointer_fact(const Value& input, const std::string& path,
                         PointerFact* out, Error* error) {
  const ObjectReader r(input, path, error);
  PointerDevice device = PointerDevice::kTouch;
  return r.check_keys({"pointerId", "phase", "x", "y", "device", "tap"}) &&
         r.req_int("pointerId", &out->pointer_id) &&
         read_named(r, "phase", kPointerPhases, &out->phase) &&
         read_point(r, "x", "y", &out->position) &&
         read_named(r, "device", kPointerDevices, &device) &&
         decode_tap_field(r, out, error);
}

bool decode_pan_zoom_fact(const Value& input, const std::string& path,
                          PanZoomFact* out, Error* error) {
  const ObjectReader r(input, path, error);
  if (!r.check_keys({"pointerId", "phase", "x", "y", "panX", "panY",
                     "scale"}) ||
      !r.req_int("pointerId", &out->pointer_id) ||
      !read_named(r, "phase", kPanZoomPhases, &out->phase) ||
      !read_point(r, "x", "y", &out->position)) {
    return false;
  }
  if (out->phase != PanZoomPhase::kUpdate) {
    return reject_present(r, {"panX", "panY", "scale"},
                          "only allowed on update");
  }
  return read_point(r, "panX", "panY", &out->pan) &&
         r.req_double("scale", &out->scale);
}

bool decode_scroll_fact(const Value& input, const std::string& path,
                        ScrollFact* out, Error* error) {
  const ObjectReader r(input, path, error);
  if (!r.check_keys({"scrollableId", "phase", "offset", "axis",
                     "maxScrollExtent", "anchor"}) ||
      !read_non_empty(r, "scrollableId", &out->scrollable_id) ||
      !read_named(r, "phase", kScrollPhases, &out->phase)) {
    return false;
  }
  if (out->phase == ScrollPhase::kOverscroll) {
    return reject_present(r, {"offset", "axis", "maxScrollExtent", "anchor"},
                          "not allowed on overscroll");
  }
  if (out->phase != ScrollPhase::kStart &&
      !reject_present(r, {"anchor"}, "only allowed on start")) {
    return false;
  }
  const Value* anchor = nullptr;
  if (!r.req_double("offset", &out->offset) ||
      !read_named(r, "axis", kScrollAxes, &out->axis) ||
      !r.opt_object("anchor", &anchor) ||
      !decode_anchor(anchor, r.child("anchor"), &out->anchor, error)) {
    return false;
  }
  if (const Value* extent = r.get("maxScrollExtent")) {
    if (!extent->is_number()) {
      return r.reject("maxScrollExtent", "expected number");
    }
    out->max_scroll_extent = extent->to_double();
  }
  return true;
}

bool decode_focus_fact(const Value& input, const std::string& path,
                       FocusKind* out, Error* error) {
  const ObjectReader r(input, path, error);
  return r.check_keys({"kind"}) && read_named(r, "kind", kFocusKinds, out);
}

bool decode_system_input_fact(const Value& input, const std::string& path,
                              SystemInput* out, Error* error) {
  const ObjectReader r(input, path, error);
  return r.check_keys({"input"}) && read_named(r, "input", kSystemInputs, out);
}

bool decode_capture_result(const Value& input, const std::string& path,
                           CaptureResult* out, Error* error) {
  const ObjectReader r(input, path, error);
  const Value* frame = nullptr;
  if (!r.check_keys({"requestId", "outcome", "frame", "boundaryRect"}) ||
      !read_non_empty(r, "requestId", &out->request_id) ||
      !read_named(r, "outcome", kCaptureOutcomes, &out->outcome) ||
      !r.opt_object("frame", &frame)) {
    return false;
  }
  if (out->outcome != CaptureResultOutcome::kCaptured) {
    return reject_present(r, {"frame", "boundaryRect"},
                          "only allowed when captured");
  }
  if (frame == nullptr) return r.reject("frame", "required when captured");
  CapturedFrame captured;
  if (!decode_frame(*frame, r.child("frame"), &captured, error) ||
      !decode_boundary(r, &captured, error)) {
    return false;
  }
  out->frame = std::move(captured);
  return true;
}

}  // namespace engine
}  // namespace tugboat
