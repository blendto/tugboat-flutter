#include "interaction_facts.h"

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

bool read_point(const ObjectReader& r, const char* x_key, const char* y_key,
                Point* out) {
  return r.req_double(x_key, &out->x) && r.req_double(y_key, &out->y);
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

}  // namespace engine
}  // namespace tugboat
