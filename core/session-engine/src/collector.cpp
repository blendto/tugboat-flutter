// Collector record mapping. Reproduces collector_mapper.dart (and the
// `toJson` of the Dart models it calls) exactly, including the quirks listed
// in conformance/README.md and the ADR 0009 slice 1 design notes. Changing
// any output here is a wire contract change.
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "dart_time.h"
#include "operations.h"
#include "tugboat/tb_session_engine.h"

namespace tugboat {
namespace engine {

namespace {

using OptString = std::optional<std::string>;

constexpr int64_t kInteractionSchemaVersion = 2;
constexpr int64_t kRouteChangeSchemaVersion = 2;

// ------------------------------------------------------------- input model

struct AppInfo {
  std::string name;
  std::string version;
  std::string build_number;
  std::string installation_id;
  std::string app_id;
};

struct DeviceInfo {
  std::string id;
  std::string platform;
  OptString manufacturer;
  OptString model;
  OptString os_version;
  std::optional<int64_t> battery_percent;
  std::optional<int64_t> storage_free_mb;
  std::optional<int64_t> ram_mb;
  OptString network_type;
  double screen_width = 0;
  double screen_height = 0;
  double screen_density = 0;
  int64_t screen_dpi = 0;
  double screen_pixel_density = 0;
};

struct IpInfo {
  std::string ip;
  OptString city;
  OptString region;
  OptString country;
  OptString timezone;
  OptString isp;
  OptString org;
};

struct ConfiguredLocale {
  OptString language;
  OptString country;
  OptString timezone;
};

struct Host {
  AppInfo app;
  DeviceInfo device;
  IpInfo ip;
  ConfiguredLocale locale;
  OptString configured_user_id;
};

struct Session {
  OptString session_id;
  int64_t started_at_ms = 0;
  OptString user_id;
  OptString traits_id;
  const Value* traits = nullptr;  // borrowed from the message
};

// Active-locale evidence (TugboatLocaleInfo).
struct LocaleInfo {
  std::string language;
  OptString country;
  OptString script;
  std::string tag;
};

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

struct Event {
  std::string id;
  int64_t at_ms = 0;
  std::string type;
  std::string stream;
  std::optional<Anchor> anchor;
  OptString before_frame;
  OptString after_frame;
  OptString result;
  OptString related_event_id;
  Value data = Value::object();
  std::optional<LocaleInfo> locale;
  OptString exploration_run_id;
  OptString action_id;
};

// ---------------------------------------------------------------- decoding

bool decode_app(const Value& json, const std::string& where, AppInfo* out,
                Error* error) {
  const ObjectReader r(json, where, error);
  return r.check_keys(
             {"name", "version", "buildNumber", "installationId", "appId"}) &&
         r.req_string("name", &out->name) &&
         r.req_string("version", &out->version) &&
         r.req_string("buildNumber", &out->build_number) &&
         r.req_string("installationId", &out->installation_id) &&
         r.req_string("appId", &out->app_id);
}

bool decode_screen(const ObjectReader& device, DeviceInfo* out, Error* error) {
  const Value* screen = nullptr;
  if (!device.req_object("screenSize", &screen)) {
    return false;
  }
  const ObjectReader r(*screen, device.child("screenSize"), error);
  return r.check_keys({"width", "height"}) &&
         r.req_double("width", &out->screen_width) &&
         r.req_double("height", &out->screen_height);
}

bool decode_device(const Value& json, const std::string& where,
                   DeviceInfo* out, Error* error) {
  const ObjectReader r(json, where, error);
  return r.check_keys({"id", "platform", "manufacturer", "model", "osVersion",
                       "batteryPercent", "storageFreeMb", "ramMb",
                       "networkType", "screenSize", "screenDensity",
                       "screenDpi", "screenPixelDensity"}) &&
         decode_screen(r, out, error) && r.req_string("id", &out->id) &&
         r.req_string("platform", &out->platform) &&
         r.opt_string("manufacturer", &out->manufacturer) &&
         r.opt_string("model", &out->model) &&
         r.opt_string("osVersion", &out->os_version) &&
         r.opt_int("batteryPercent", &out->battery_percent) &&
         r.opt_int("storageFreeMb", &out->storage_free_mb) &&
         r.opt_int("ramMb", &out->ram_mb) &&
         r.opt_string("networkType", &out->network_type) &&
         r.req_double("screenDensity", &out->screen_density) &&
         r.req_int("screenDpi", &out->screen_dpi) &&
         r.req_double("screenPixelDensity", &out->screen_pixel_density);
}

bool decode_ip(const Value& json, const std::string& where, IpInfo* out,
               Error* error) {
  const ObjectReader r(json, where, error);
  return r.check_keys(
             {"ip", "city", "region", "country", "timezone", "isp", "org"}) &&
         r.req_string("ip", &out->ip) && r.opt_string("city", &out->city) &&
         r.opt_string("region", &out->region) &&
         r.opt_string("country", &out->country) &&
         r.opt_string("timezone", &out->timezone) &&
         r.opt_string("isp", &out->isp) && r.opt_string("org", &out->org);
}

bool decode_configured_locale(const Value& json, const std::string& where,
                              ConfiguredLocale* out, Error* error) {
  const ObjectReader r(json, where, error);
  return r.check_keys({"language", "country", "timezone"}) &&
         r.opt_string("language", &out->language) &&
         r.opt_string("country", &out->country) &&
         r.opt_string("timezone", &out->timezone);
}

bool decode_host(const ObjectReader& input, Host* out, Error* error) {
  const Value* json = nullptr;
  if (!input.req_object("host", &json)) {
    return false;
  }
  const ObjectReader r(*json, input.child("host"), error);
  const Value* app = nullptr;
  const Value* device = nullptr;
  const Value* ip = nullptr;
  const Value* locale = nullptr;
  return r.check_keys({"app", "device", "ip", "locale", "configuredUserId"}) &&
         r.req_object("app", &app) &&
         decode_app(*app, r.child("app"), &out->app, error) &&
         r.req_object("device", &device) &&
         decode_device(*device, r.child("device"), &out->device, error) &&
         r.req_object("ip", &ip) &&
         decode_ip(*ip, r.child("ip"), &out->ip, error) &&
         r.req_object("locale", &locale) &&
         decode_configured_locale(*locale, r.child("locale"), &out->locale,
                                  error) &&
         r.opt_string("configuredUserId", &out->configured_user_id);
}

bool decode_session(const ObjectReader& input, Session* out, Error* error) {
  const Value* json = nullptr;
  if (!input.req_object("session", &json)) {
    return false;
  }
  const ObjectReader r(*json, input.child("session"), error);
  if (!r.check_keys(
          {"sessionId", "startedAtEpochMs", "userId", "traitsId", "traits"}) ||
      !r.opt_string("sessionId", &out->session_id) ||
      !r.req_int("startedAtEpochMs", &out->started_at_ms) ||
      !r.opt_string("userId", &out->user_id) ||
      !r.opt_string("traitsId", &out->traits_id) ||
      !r.opt_object("traits", &out->traits)) {
    return false;
  }
  if (!epoch_ms_in_range(out->started_at_ms)) {
    return invalid(error, r.child("startedAtEpochMs"),
                   "outside the DateTime range");
  }
  return true;
}

// `*present` is false when the locale is absent or null.
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

bool check_event_enums(const ObjectReader& r, const Event& event,
                       Error* error) {
  // TugboatEventStream.parse and TugboatInteractionResult.values.byName
  // reject anything outside the Dart enums.
  if (event.stream != "semantic" && event.stream != "evidence" &&
      event.stream != "diagnostic") {
    return invalid(error, r.child("stream"), "unsupported stream");
  }
  if (event.result && *event.result != "changed" &&
      *event.result != "noVisibleChange" && *event.result != "navigated" &&
      *event.result != "unknown") {
    return invalid(error, r.child("result"), "unsupported result");
  }
  return true;
}

bool decode_event(const ObjectReader& input, Event* out, Error* error) {
  const Value* json = nullptr;
  if (!input.req_object("event", &json)) {
    return false;
  }
  const ObjectReader r(*json, input.child("event"), error);
  const Value* anchor = nullptr;
  const Value* data = nullptr;
  if (!r.check_keys({"id", "atMs", "type", "stream", "targetAnchor",
                     "beforeFrame", "afterFrame", "result", "relatedEventId",
                     "data", "locale", "explorationRunId", "actionId"}) ||
      !r.req_string("id", &out->id) || !r.req_int("atMs", &out->at_ms) ||
      !r.req_string("type", &out->type) ||
      !r.req_string("stream", &out->stream) ||
      !r.opt_object("targetAnchor", &anchor) ||
      !decode_anchor(anchor, r.child("targetAnchor"), &out->anchor, error) ||
      !r.opt_string("beforeFrame", &out->before_frame) ||
      !r.opt_string("afterFrame", &out->after_frame) ||
      !r.opt_string("result", &out->result) ||
      !r.opt_string("relatedEventId", &out->related_event_id) ||
      !r.opt_object("data", &data) ||
      !decode_locale(r.get("locale"), r.child("locale"), &out->locale,
                     error) ||
      !r.opt_string("explorationRunId", &out->exploration_run_id) ||
      !r.opt_string("actionId", &out->action_id) ||
      !check_event_enums(r, *out, error)) {
    return false;
  }
  if (data != nullptr) {
    out->data = *data;
  }
  return true;
}

// ------------------------------------------------------------------ output

Value str(const std::string& s) { return Value::string(s); }

// Writes `value` under `key` only when present (Dart `if (x != null)`).
void put_opt(Value* object, const char* key, const OptString& value) {
  if (value) {
    object->set(key, str(*value));
  }
}

// Dart `if (x != null && x!.isNotEmpty)`.
void put_non_empty(Value* object, const char* key, const OptString& value) {
  if (value && !value->empty()) {
    object->set(key, str(*value));
  }
}

Value string_list(const std::vector<std::string>& items) {
  Value out = Value::array();
  for (const std::string& item : items) {
    out.push(str(item));
  }
  return out;
}

// TugboatLocaleInfo.toJson: country and script are dropped when empty.
Value locale_json(const LocaleInfo& locale) {
  Value out = Value::object();
  out.set("language", str(locale.language));
  put_non_empty(&out, "country", locale.country);
  put_non_empty(&out, "script", locale.script);
  out.set("tag", str(locale.tag));
  return out;
}

// TugboatTargetAnchor.toJson (generic envelope): schemaVersion only when not
// 1, fingerprintParts kept.
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

// _collectorInteractionTargetAnchor: reduced anchor for flat interaction
// records (no schemaVersion, no fingerprintParts, different key order), or
// nothing when every field is dropped.
std::optional<Value> interaction_anchor_json(const std::optional<Anchor>& in) {
  if (!in) {
    return std::nullopt;
  }
  const Anchor& anchor = *in;
  Value out = Value::object();
  put_non_empty(&out, "fingerprint", anchor.fingerprint);
  put_non_empty(&out, "canonicalPath", anchor.canonical_path);
  put_opt(&out, "widgetType", anchor.widget_type);
  put_opt(&out, "role", anchor.role);
  put_non_empty(&out, "fingerprintConfidence", anchor.fingerprint_confidence);
  put_non_empty(&out, "tagFingerprint", anchor.tag_fingerprint);
  put_opt(&out, "relativePosition", anchor.relative_position);
  if (anchor.enabled) {
    out.set("enabled", Value::boolean(*anchor.enabled));
  }
  if (!anchor.actions.empty()) {
    out.set("actions", string_list(anchor.actions));
  }
  if (out.members().empty()) {
    return std::nullopt;
  }
  return out;
}

// collectorEventBuildIdentity.
Value build_identity(const Host& host) {
  Value out = Value::object();
  out.set("appId", str(host.app.app_id));
  out.set("platform", str(host.device.platform));
  out.set("versionName", str(host.app.version));
  out.set("buildNumber", str(host.app.build_number));
  out.set("fingerprintSchemaVersion",
          Value::integer(TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION));
  return out;
}

// `data[key]` when present and not null.
const Value* data_value(const Value& data, const char* key) {
  const Value* value = data.find(key);
  return value == nullptr || value->is_null() ? nullptr : value;
}

struct EnvelopeContext {
  const Event& event;
  const Host& host;
  const Session& session;
  std::string triggered_at;
};

// Keys every event envelope starts with.
Value envelope_head(const EnvelopeContext& ctx) {
  const Event& event = ctx.event;
  Value out = Value::object();
  out.set("id", str(event.id));
  out.set("atMs", Value::integer(event.at_ms));
  out.set("triggeredAt", str(ctx.triggered_at));
  // sessionId is omitted when null, but userId is always present.
  put_opt(&out, "sessionId", ctx.session.session_id);
  out.set("userId",
          ctx.session.user_id ? str(*ctx.session.user_id) : Value::null());
  out.set("eventType", str(event.type));
  out.set("stream", str(event.stream));
  out.set("enrichmentCandidate", Value::boolean(event.type == "interaction"));
  return out;
}

// _collectorFlatEnvelope (interaction, route_change).
Value flat_envelope(const EnvelopeContext& ctx, Value extra) {
  const Event& event = ctx.event;
  Value out = envelope_head(ctx);
  for (Member& member : extra.members()) {
    out.set(member.key, std::move(member.value));
  }
  put_opt(&out, "relatedEventId", event.related_event_id);
  put_opt(&out, "beforeFrame", event.before_frame);
  put_opt(&out, "afterFrame", event.after_frame);
  put_opt(&out, "explorationRunId", event.exploration_run_id);
  put_opt(&out, "actionId", event.action_id);
  if (event.locale) {
    out.set("locale", locale_json(*event.locale));
  }
  put_opt(&out, "traitsId", ctx.session.traits_id);
  out.set("build", build_identity(ctx.host));
  return out;
}

// _collectorGenericEnvelope (network_call and every other type). Keeps
// result and the full anchor, which flat envelopes drop.
Value generic_envelope(const EnvelopeContext& ctx, Value payload) {
  const Event& event = ctx.event;
  Value out = envelope_head(ctx);
  put_opt(&out, "explorationRunId", event.exploration_run_id);
  put_opt(&out, "actionId", event.action_id);
  if (event.locale) {
    out.set("locale", locale_json(*event.locale));
  }
  put_opt(&out, "beforeFrame", event.before_frame);
  put_opt(&out, "afterFrame", event.after_frame);
  put_opt(&out, "traitsId", ctx.session.traits_id);
  if (event.anchor) {
    out.set("targetAnchor", anchor_json(*event.anchor));
  }
  put_opt(&out, "result", event.result);  // camelCase enum name
  out.set("payload", std::move(payload));
  out.set("build", build_identity(ctx.host));
  return out;
}

Value interaction_extra(const Event& event) {
  const Value& data = event.data;
  Value extra = Value::object();
  // Unknown gesture / interactionSchema values pass through unvalidated.
  const Value* schema = data_value(data, "interactionSchema");
  extra.set("interactionSchema",
            schema != nullptr ? *schema
                              : Value::integer(kInteractionSchemaVersion));
  for (const char* key : {"route", "targetFingerprint", "fingerprintConfidence",
                          "targetResolutionFailureReason", "gesture",
                          "payload"}) {
    if (const Value* value = data_value(data, key)) {
      extra.set(key, *value);
    }
  }
  if (std::optional<Value> anchor = interaction_anchor_json(event.anchor)) {
    extra.set("targetAnchor", std::move(*anchor));
  }
  return extra;
}

// _routeChangeCollectorKeys, in order.
const char* const kRouteChangeKeys[] = {
    "fromRoute",
    "route",
    "navigation",
    "causeEventId",
    "causedByInteractionId",
    "routeName",
    "routeType",
    "routeNamed",
    "fromRouteName",
    "fromRouteType",
    "fromRouteNamed",
    "overlayKind",
    "presentedOverRoute",
    "presentedOverRouteInstanceId",
    "presentedOverOverlayKind",
    "hostPageRoute",
    "hostPageRouteInstanceId",
    "routeStack",
    "causeTargetFingerprint",
    "causeGesture",
};

Value route_change_extra(const Value& data) {
  Value extra = Value::object();
  extra.set("routeChangeSchema", Value::integer(kRouteChangeSchemaVersion));
  for (const char* key : kRouteChangeKeys) {
    if (const Value* value = data_value(data, key)) {
      extra.set(key, *value);
    }
  }
  const Value* truncated = data.find("routeStackTruncated");
  if (truncated != nullptr && truncated->is_bool() && truncated->as_bool()) {
    extra.set("routeStackTruncated", Value::boolean(true));
  }
  return extra;
}

bool int_in(const Value* value, int64_t low, int64_t high) {
  return value != nullptr && value->is_int() && value->as_int() >= low &&
         value->as_int() <= high;
}

// _networkCallCollectorPayload: each field kept only when it passes the
// mapper's type and range checks; relatedEventId is not carried.
Value network_call_payload(const Value& data, const std::string& stream) {
  const Value* method = data.find("method");
  const Value* route = data.find("route");
  const Value* status_code = data.find("statusCode");
  const Value* outcome = data.find("outcome");
  const Value* duration = data.find("durationMs");
  const Value* attempts = data.find("attemptCount");
  const Value* error_body = data.find("errorResponseBody");
  const bool is_response =
      outcome != nullptr && outcome->is_string() &&
      outcome->as_string() == "response";
  const bool is_api_error = is_response && int_in(status_code, 400, 599);

  Value payload = Value::object();
  if (method != nullptr && method->is_string()) {
    payload.set("method", *method);
  }
  if (route != nullptr && route->is_string()) {
    payload.set("route", *route);
  }
  if (is_response && int_in(status_code, 100, 599)) {
    payload.set("statusCode", *status_code);
  }
  if (outcome != nullptr && outcome->is_string() &&
      (outcome->as_string() == "response" ||
       outcome->as_string() == "network_error" ||
       outcome->as_string() == "cancelled")) {
    payload.set("outcome", *outcome);
  }
  if (duration != nullptr && duration->is_int()) {
    payload.set("durationMs", *duration);
  }
  if (attempts != nullptr && attempts->is_int() && attempts->as_int() > 0) {
    payload.set("attemptCount", *attempts);
  }
  // _isWireErrorBody: any non-null JSON value.
  if (is_api_error && error_body != nullptr && !error_body->is_null()) {
    payload.set("errorResponseBody", *error_body);
  }
  payload.set("stream", str(stream));
  return payload;
}

// Generic payload: `{...data, relatedEventId?, explorationRunId?,
// actionId?}` with Dart map-literal semantics (a later key replaces an
// earlier one in place).
Value generic_payload(const Event& event) {
  Value payload = event.data;
  put_opt(&payload, "relatedEventId", event.related_event_id);
  put_opt(&payload, "explorationRunId", event.exploration_run_id);
  put_opt(&payload, "actionId", event.action_id);
  return payload;
}

Value map_event(const EnvelopeContext& ctx) {
  const Event& event = ctx.event;
  if (event.type == "interaction") {
    return flat_envelope(ctx, interaction_extra(event));
  }
  if (event.type == "route_change") {
    return flat_envelope(ctx, route_change_extra(event.data));
  }
  if (event.type == "network_call") {
    return generic_envelope(ctx, network_call_payload(event.data, event.stream));
  }
  return generic_envelope(ctx, generic_payload(event));
}

// session_start host metadata. The active locale removes the configured
// language/country/script/tag even when it lacks them.
void add_session_start_metadata(const Host& host,
                                const std::optional<LocaleInfo>& active,
                                Value* body) {
  Value app = Value::object();
  app.set("version", str(host.app.version));
  app.set("buildNumber", str(host.app.build_number));
  app.set("appId", str(host.app.app_id));
  app.set("packageName", str(host.app.app_id));

  const DeviceInfo& d = host.device;
  Value device = Value::object();
  device.set("id", str(d.id));
  device.set("platform", str(d.platform));
  put_opt(&device, "manufacturer", d.manufacturer);
  put_opt(&device, "model", d.model);
  put_opt(&device, "osVersion", d.os_version);
  if (d.battery_percent) {
    device.set("batteryPercent", Value::integer(*d.battery_percent));
  }
  if (d.storage_free_mb) {
    device.set("storageFreeMb", Value::integer(*d.storage_free_mb));
  }
  if (d.ram_mb) {
    device.set("ramMb", Value::integer(*d.ram_mb));
  }
  put_opt(&device, "networkType", d.network_type);
  Value screen = Value::object();
  screen.set("width", Value::number(d.screen_width));
  screen.set("height", Value::number(d.screen_height));
  device.set("screenSize", std::move(screen));
  device.set("screenDensity", Value::number(d.screen_density));
  device.set("screenDpi", Value::integer(d.screen_dpi));
  device.set("screenPixelDensity", Value::number(d.screen_pixel_density));

  const IpInfo& i = host.ip;
  Value ip = Value::object();
  ip.set("ip", str(i.ip));
  put_opt(&ip, "city", i.city);
  put_opt(&ip, "region", i.region);
  put_opt(&ip, "country", i.country);
  put_opt(&ip, "timezone", i.timezone);
  put_opt(&ip, "isp", i.isp);
  put_opt(&ip, "org", i.org);

  Value locale = Value::object();
  put_opt(&locale, "language", host.locale.language);
  put_opt(&locale, "country", host.locale.country);
  put_opt(&locale, "timezone", host.locale.timezone);
  if (active) {
    for (const char* key : {"language", "country", "script", "tag"}) {
      locale.remove(key);
    }
    Value active_json = locale_json(*active);
    for (Member& member : active_json.members()) {
      locale.set(member.key, std::move(member.value));
    }
  }

  body->set("appInfo", std::move(app));
  body->set("device", std::move(device));
  body->set("ipInfo", std::move(ip));
  body->set("locale", std::move(locale));
}

}  // namespace

bool run_collector_event(const Value& input, Value* result, Error* error) {
  const ObjectReader r(input, "$.input", error);
  Host host;
  Session session;
  Event event;
  if (!r.check_keys({"host", "session", "event"}) ||
      !decode_host(r, &host, error) || !decode_session(r, &session, error)) {
    return false;
  }
  if (session.traits != nullptr) {
    return invalid(error, "$.input.session.traits", "lifecycle only");
  }
  if (!decode_event(r, &event, error)) {
    return false;
  }
  int64_t triggered_us = 0;
  if (!dart_add_ms(session.started_at_ms, event.at_ms, &triggered_us)) {
    return invalid(error, "$.input.event.atMs",
                   "triggeredAt outside the DateTime range");
  }
  const EnvelopeContext ctx{event, host, session,
                            dart_iso8601_utc(triggered_us)};
  *result = Value::object();
  result->set("record", map_event(ctx));
  return true;
}

bool run_session_lifecycle(const Value& input, Value* result, Error* error) {
  const ObjectReader r(input, "$.input", error);
  Host host;
  Session session;
  const Value* lifecycle_json = nullptr;
  if (!r.check_keys({"host", "session", "lifecycle"}) ||
      !decode_host(r, &host, error) || !decode_session(r, &session, error) ||
      !r.req_object("lifecycle", &lifecycle_json)) {
    return false;
  }
  const ObjectReader lr(*lifecycle_json, r.child("lifecycle"), error);
  std::string event_type;
  int64_t triggered_ms = 0;
  std::optional<LocaleInfo> active_locale;
  if (!lr.check_keys({"eventType", "triggeredAtEpochMs", "activeLocale"})) {
    return false;
  }
  if (!session.session_id) {
    return invalid(error, "$.input.session.sessionId", "required");
  }
  if (!lr.req_string("eventType", &event_type) ||
      !lr.req_int("triggeredAtEpochMs", &triggered_ms) ||
      !decode_locale(lr.get("activeLocale"), lr.child("activeLocale"),
                     &active_locale, error)) {
    return false;
  }
  if (!epoch_ms_in_range(triggered_ms)) {
    return invalid(error, lr.child("triggeredAtEpochMs"),
                   "outside the DateTime range");
  }

  // Any eventType other than session_start is a non-start record.
  const bool is_start = event_type == "session_start";
  Value body = Value::object();
  body.set("sessionId", str(*session.session_id));
  body.set("eventType", str(event_type));
  // Wall-clock difference, not clamped: may be negative.
  body.set("atMs", Value::integer(triggered_ms - session.started_at_ms));
  body.set("triggeredAt", str(dart_iso8601_utc(triggered_ms * 1000)));
  // Only session_start falls back to the configured startup user id.
  OptString user_id = session.user_id;
  if (is_start && !user_id) {
    user_id = host.configured_user_id;
  }
  body.set("userId", user_id ? str(*user_id) : Value::null());
  if (is_start) {
    add_session_start_metadata(host, active_locale, &body);
  }
  // A full traits bag wins over the traitsId pass-through.
  if (session.traits != nullptr) {
    body.set("traits", *session.traits);
  } else if (session.traits_id) {
    body.set("traitsId", str(*session.traits_id));
  }
  *result = Value::object();
  result->set("record", std::move(body));
  return true;
}

}  // namespace engine
}  // namespace tugboat
