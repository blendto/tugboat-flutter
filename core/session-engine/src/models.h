// Typed session models shared by the stateless collector mapping and the
// stateful engine: locale evidence, target anchors, and recorded events.
// They mirror the Dart models in `models.dart` and `anchor_models.dart`; the
// `*_json` functions reproduce their `toJson` exactly. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_MODELS_H
#define TUGBOAT_SESSION_ENGINE_MODELS_H

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "json.h"
#include "reader.h"

namespace tugboat {
namespace engine {

using OptString = std::optional<std::string>;

// Active-locale evidence (TugboatLocaleInfo). Evidence, never identity.
struct LocaleInfo {
  std::string language;
  OptString country;
  OptString script;
  std::string tag;

  // Dart `==`: field by field, so an empty country differs from none.
  bool operator==(const LocaleInfo& other) const {
    return language == other.language && country == other.country &&
           script == other.script && tag == other.tag;
  }
  bool operator!=(const LocaleInfo& other) const { return !(*this == other); }
};

// The UI toolkit an adapter resolved an anchor in (ADR 0009). Evidence
// carried through to records and the collector wire, never a fingerprint
// input; Flutter anchors carry none.
enum class AnchorToolkit { kView, kCompose, kSwiftUi, kUiKit, kReactNative };

const char* anchor_toolkit_name(AnchorToolkit toolkit);

// TugboatTargetAnchor, plus the native adapters' `toolkit`.
struct Anchor {
  int64_t schema_version = 1;
  OptString widget_type;
  OptString role;
  OptString fingerprint;
  OptString fingerprint_confidence;
  OptString tag_fingerprint;
  std::vector<Member> fingerprint_parts;  // string values, input order
  OptString canonical_path;
  OptString relative_position;
  std::optional<bool> enabled;
  std::vector<std::string> actions;
  std::optional<AnchorToolkit> toolkit;
};

// TugboatEventStream (session schema 10).
enum class EventStream { kSemantic, kEvidence, kDiagnostic };

const char* stream_name(EventStream stream);
std::optional<EventStream> parse_stream(const std::string& name);

// TugboatFrameTrigger.
enum class FrameTrigger {
  kInitial,
  kTap,
  kScroll,
  kRoute,
  kLifecycle,
  kManual,
  kInteraction,
};

const char* frame_trigger_name(FrameTrigger trigger);

// TugboatEvent: one recorded session event. `data` is the type-specific bag
// the producer supplies; the engine passes it through unchanged.
struct Event {
  std::string id;
  int64_t at_ms = 0;
  std::string type;
  EventStream stream = EventStream::kSemantic;
  OptString capture_session_id;
  OptString activation_request_id;
  std::optional<Anchor> anchor;
  OptString before_frame;
  OptString after_frame;
  OptString result;  // TugboatInteractionResult name
  OptString related_event_id;
  Value data = Value::object();
  std::optional<LocaleInfo> locale;
  OptString exploration_run_id;
  OptString action_id;
};

// TugboatFrame: metadata of one accepted frame. Its bytes stay in the host.
struct Frame {
  std::string id;
  int64_t at_ms = 0;
  int64_t width = 0;
  int64_t height = 0;
  std::string content_hash;
  bool masked = false;
  FrameTrigger trigger = FrameTrigger::kManual;
  int64_t byte_length = 0;
  int64_t capture_micros = 0;
  OptString capture_session_id;
  OptString requested_backend;
  OptString resolved_backend;
  OptString fallback_reason;
};

// Decodes locale evidence; `*out` stays empty when `json` is absent or null.
bool decode_locale(const Value* json, const std::string& where,
                   std::optional<LocaleInfo>* out, Error* error);

// Decodes an anchor object (`json` may be nullptr for "absent").
bool decode_anchor(const Value* json, const std::string& where,
                   std::optional<Anchor>* out, Error* error);

// TugboatLocaleInfo.toJson: country and script are dropped when empty.
Value locale_json(const LocaleInfo& locale);

// TugboatTargetAnchor.toJson: schemaVersion only when not 1; `toolkit`
// last, only when present.
Value anchor_json(const Anchor& anchor);

// TugboatEvent.toJson.
Value event_json(const Event& event);

// TugboatFrame.toJson.
Value frame_json(const Frame& frame);

// Writes `value` under `key` only when present (Dart `if (x != null)`).
void put_opt(Value* object, const char* key, const OptString& value);

// Dart `if (x != null && x!.isNotEmpty)`.
void put_non_empty(Value* object, const char* key, const OptString& value);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_MODELS_H
