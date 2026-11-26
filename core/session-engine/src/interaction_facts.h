// The interaction facts of docs/stateful-engine.md section 9.1, as typed
// models, with their strict decoders. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_FACTS_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_FACTS_H

#include <cstdint>
#include <optional>
#include <string>

#include "interaction_types.h"
#include "json.h"
#include "models.h"
#include "reader.h"
#include "tap_evidence.h"

namespace tugboat {
namespace engine {

// `input.pointer {pointerId, phase, x, y, device, tap?}`. `device` (touch,
// mouse, stylus, trackpad) is validated but, as in Dart, does not change
// classification. `tap` is allowed on `down` and `up` only.
enum class PointerPhase { kDown, kMove, kUp, kCancel };

struct PointerFact {
  int64_t pointer_id = 0;
  PointerPhase phase = PointerPhase::kDown;
  Point position;
  std::optional<TapEvidence> tap;
};

// `input.panZoom {pointerId, phase, x, y, panX?, panY?, scale?}`: a trackpad
// pan/zoom contact at `x, y`. `panX`, `panY`, and `scale` (cumulative since
// start) are required on `update` and not allowed otherwise.
enum class PanZoomPhase { kStart, kUpdate, kEnd };

struct PanZoomFact {
  int64_t pointer_id = 0;
  PanZoomPhase phase = PanZoomPhase::kStart;
  Point position;
  Point pan;
  double scale = 1;
};

// `scroll {scrollableId, phase, offset?, axis?, maxScrollExtent?, anchor?}`.
// `offset` and `axis` are required on start, update, and end;
// `maxScrollExtent` is optional there; `anchor` is allowed on start only.
// `overscroll` carries only the id.
enum class ScrollPhase { kStart, kUpdate, kEnd, kOverscroll };

// Dart `Axis`.
enum class ScrollAxis { kVertical, kHorizontal };

const char* scroll_axis_name(ScrollAxis axis);

struct ScrollFact {
  std::string scrollable_id;
  ScrollPhase phase = ScrollPhase::kStart;
  double offset = 0;
  ScrollAxis axis = ScrollAxis::kVertical;
  std::optional<double> max_scroll_extent;
  std::optional<Anchor> anchor;
};

// `focus {kind}`: the kind of node that now holds primary focus.
enum class FocusKind { kTextInput, kOther, kNone };

const char* focus_kind_name(FocusKind kind);

// `systemInput {input}`: one allowlisted system input.
enum class SystemInput {
  kBack,
  kVolumeUp,
  kVolumeDown,
  kVolumeMute,
  kPower,
  kMediaPlayPause,
};

const char* system_input_name(SystemInput input);

// Each decoder reads the message `input` object at JSON path `path`.
bool decode_pointer_fact(const Value& input, const std::string& path,
                         PointerFact* out, Error* error);
bool decode_pan_zoom_fact(const Value& input, const std::string& path,
                          PanZoomFact* out, Error* error);
bool decode_scroll_fact(const Value& input, const std::string& path,
                        ScrollFact* out, Error* error);
bool decode_focus_fact(const Value& input, const std::string& path,
                       FocusKind* out, Error* error);
bool decode_system_input_fact(const Value& input, const std::string& path,
                              SystemInput* out, Error* error);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_FACTS_H
