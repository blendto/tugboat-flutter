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

// TugboatTargetAnchor.
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
};

// TugboatEventStream plus the collector's `legacy_projection`. The Dart enum
// has no `legacy_projection` (schema 10 removed it); only the stateful
// `event.record` accepts it, because the collector still does.
enum class EventStream { kSemantic, kEvidence, kDiagnostic, kLegacyProjection };

const char* stream_name(EventStream stream);
// Parses a stream name. `allow_legacy` admits `legacy_projection`.
std::optional<EventStream> parse_stream(const std::string& name,
                                        bool allow_legacy);

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

// Decodes locale evidence; `*out` stays empty when `json` is absent or null.
bool decode_locale(const Value* json, const std::string& where,
                   std::optional<LocaleInfo>* out, Error* error);

// Decodes an anchor object (`json` may be nullptr for "absent").
bool decode_anchor(const Value* json, const std::string& where,
                   std::optional<Anchor>* out, Error* error);

// TugboatLocaleInfo.toJson: country and script are dropped when empty.
Value locale_json(const LocaleInfo& locale);

// TugboatTargetAnchor.toJson: schemaVersion only when not 1.
Value anchor_json(const Anchor& anchor);

// TugboatEvent.toJson.
Value event_json(const Event& event);

// Writes `value` under `key` only when present (Dart `if (x != null)`).
void put_opt(Value* object, const char* key, const OptString& value);

// Dart `if (x != null && x!.isNotEmpty)`.
void put_non_empty(Value* object, const char* key, const OptString& value);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_MODELS_H
