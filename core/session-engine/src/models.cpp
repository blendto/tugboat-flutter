#include "models.h"

#include <utility>

namespace tugboat {
namespace engine {

namespace {

Value str(const std::string& s) { return Value::string(s); }

Value string_list(const std::vector<std::string>& items) {
  Value out = Value::array();
  for (const std::string& item : items) {
    out.push(str(item));
  }
  return out;
}

bool decode_anchor_lists(const ObjectReader& r, Anchor* out, Error* error) {
  const Value* parts = nullptr;
  if (!r.opt_object("fingerprintParts", &parts)) {
    return false;
  }
  if (parts != nullptr) {
    for (const Member& member : parts->members()) {
      if (!member.value.is_string()) {
        // Map<String, String>.from throws on a non-string value.
        return invalid(error, r.child("fingerprintParts") + "." + member.key,
                       "expected string");
      }
      out->fingerprint_parts.push_back(member);
    }
  }
  const Value* actions = r.get("actions");
  if (actions == nullptr) {
    return true;
  }
  if (!actions->is_array()) {
    return invalid(error, r.child("actions"), "expected array");
  }
  size_t index = 0;
  for (const Value& action : actions->items()) {
    if (!action.is_string()) {
      // `.cast<String>()` fails when the list is encoded.
      return invalid(error,
                     r.child("actions") + "[" + std::to_string(index) + "]",
                     "expected string");
    }
    out->actions.push_back(action.as_string());
    ++index;
  }
  return true;
}

}  // namespace

const char* stream_name(EventStream stream) {
  switch (stream) {
    case EventStream::kSemantic: return "semantic";
    case EventStream::kEvidence: return "evidence";
    case EventStream::kDiagnostic: return "diagnostic";
    case EventStream::kLegacyProjection: return "legacy_projection";
  }
  return "semantic";
}

std::optional<EventStream> parse_stream(const std::string& name,
                                        bool allow_legacy) {
  if (name == "semantic") {
    return EventStream::kSemantic;
  }
  if (name == "evidence") {
    return EventStream::kEvidence;
  }
  if (name == "diagnostic") {
    return EventStream::kDiagnostic;
  }
  if (allow_legacy && name == "legacy_projection") {
    return EventStream::kLegacyProjection;
  }
  return std::nullopt;
}

void put_opt(Value* object, const char* key, const OptString& value) {
  if (value) {
    object->set(key, str(*value));
  }
}

void put_non_empty(Value* object, const char* key, const OptString& value) {
  if (value && !value->empty()) {
    object->set(key, str(*value));
  }
}

bool decode_locale(const Value* json, const std::string& where,
                   std::optional<LocaleInfo>* out, Error* error) {
  out->reset();
  if (json == nullptr || json->is_null()) {
    return true;
  }
  if (!json->is_object()) {
    return invalid(error, where, "expected object");
  }
  const ObjectReader r(*json, where, error);
  LocaleInfo locale;
  if (!r.check_keys({"language", "country", "script", "tag"}) ||
      !r.req_string("language", &locale.language) ||
      !r.opt_string("country", &locale.country) ||
      !r.opt_string("script", &locale.script) ||
      !r.req_string("tag", &locale.tag)) {
    return false;
  }
  *out = std::move(locale);
  return true;
}

bool decode_anchor(const Value* json, const std::string& where,
                   std::optional<Anchor>* out, Error* error) {
  out->reset();
  if (json == nullptr) {
    return true;
  }
  const ObjectReader r(*json, where, error);
  Anchor anchor;
  std::optional<int64_t> schema_version;
  if (!r.check_keys({"schemaVersion", "widgetType", "role", "fingerprint",
                     "fingerprintConfidence", "tagFingerprint",
                     "fingerprintParts", "canonicalPath", "relativePosition",
                     "enabled", "actions"}) ||
      !r.opt_int("schemaVersion", &schema_version) ||
      !r.opt_string("widgetType", &anchor.widget_type) ||
      !r.opt_string("role", &anchor.role) ||
      !r.opt_string("fingerprint", &anchor.fingerprint) ||
      !r.opt_string("fingerprintConfidence", &anchor.fingerprint_confidence) ||
      !r.opt_string("tagFingerprint", &anchor.tag_fingerprint) ||
      !r.opt_string("canonicalPath", &anchor.canonical_path) ||
      !r.opt_string("relativePosition", &anchor.relative_position) ||
      !r.opt_bool("enabled", &anchor.enabled) ||
      !decode_anchor_lists(r, &anchor, error)) {
    return false;
  }
  anchor.schema_version = schema_version.value_or(1);
  *out = std::move(anchor);
  return true;
}

Value locale_json(const LocaleInfo& locale) {
  Value out = Value::object();
  out.set("language", str(locale.language));
  put_non_empty(&out, "country", locale.country);
  put_non_empty(&out, "script", locale.script);
  out.set("tag", str(locale.tag));
  return out;
}

Value anchor_json(const Anchor& anchor) {
  Value out = Value::object();
  if (anchor.schema_version != 1) {
    out.set("schemaVersion", Value::integer(anchor.schema_version));
  }
  put_opt(&out, "widgetType", anchor.widget_type);
  put_opt(&out, "role", anchor.role);
  put_non_empty(&out, "fingerprint", anchor.fingerprint);
  put_non_empty(&out, "fingerprintConfidence", anchor.fingerprint_confidence);
  put_non_empty(&out, "tagFingerprint", anchor.tag_fingerprint);
  if (!anchor.fingerprint_parts.empty()) {
    Value parts = Value::object();
    parts.members() = anchor.fingerprint_parts;
    out.set("fingerprintParts", std::move(parts));
  }
  put_non_empty(&out, "canonicalPath", anchor.canonical_path);
  put_opt(&out, "relativePosition", anchor.relative_position);
  if (anchor.enabled) {
    out.set("enabled", Value::boolean(*anchor.enabled));
  }
  if (!anchor.actions.empty()) {
    out.set("actions", string_list(anchor.actions));
  }
  return out;
}

Value event_json(const Event& event) {
  Value out = Value::object();
  out.set("id", str(event.id));
  out.set("atMs", Value::integer(event.at_ms));
  out.set("type", str(event.type));
  out.set("stream", str(stream_name(event.stream)));
  put_opt(&out, "captureSessionId", event.capture_session_id);
  put_opt(&out, "activationRequestId", event.activation_request_id);
  if (event.anchor) {
    out.set("targetAnchor", anchor_json(*event.anchor));
  }
  put_opt(&out, "beforeFrame", event.before_frame);
  put_opt(&out, "afterFrame", event.after_frame);
  put_opt(&out, "result", event.result);
  put_opt(&out, "relatedEventId", event.related_event_id);
  if (!event.data.members().empty()) {
    out.set("data", event.data);
  }
  if (event.locale) {
    out.set("locale", locale_json(*event.locale));
  }
  put_opt(&out, "explorationRunId", event.exploration_run_id);
  put_opt(&out, "actionId", event.action_id);
  return out;
}

}  // namespace engine
}  // namespace tugboat
