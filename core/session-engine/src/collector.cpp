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
#include "host.h"
#include "models.h"
#include "operations.h"
#include "tugboat/tb_session_engine.h"

namespace tugboat {
namespace engine {

namespace {

constexpr int64_t kInteractionSchemaVersion = 2;
constexpr int64_t kRouteChangeSchemaVersion = 2;

struct CollectorSession {
  OptString session_id;
  int64_t started_at_ms = 0;
  OptString user_id;
  OptString traits_id;
  const Value* traits = nullptr;  // borrowed from the message
};

// ---------------------------------------------------------------- decoding

bool decode_input_host(const ObjectReader& input, Host* out, Error* error) {
  const Value* json = nullptr;
  return input.req_object("host", &json) &&
         decode_host(*json, input.child("host"), out, error);
}

bool decode_session(const ObjectReader& input, CollectorSession* out,
                    Error* error) {
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

bool check_event_enums(const ObjectReader& r, const std::string& stream,
                       Event* event, Error* error) {
  // TugboatEventStream.parse and TugboatInteractionResult.values.byName
  // reject anything outside the Dart enums.
  const std::optional<EventStream> parsed = parse_stream(stream);
  if (!parsed) {
    return invalid(error, r.child("stream"), "unsupported stream");
  }
  event->stream = *parsed;
  if (event->result && *event->result != "changed" &&
      *event->result != "noVisibleChange" && *event->result != "navigated" &&
      *event->result != "unknown") {
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
  std::string stream;
  if (!r.check_keys({"id", "atMs", "type", "stream", "targetAnchor",
                     "beforeFrame", "afterFrame", "result", "relatedEventId",
                     "data", "locale", "explorationRunId", "actionId"}) ||
      !r.req_string("id", &out->id) || !r.req_int("atMs", &out->at_ms) ||
      !r.req_string("type", &out->type) ||
      !r.req_string("stream", &stream) ||
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
      !check_event_enums(r, stream, out, error)) {
    return false;
  }
  if (data != nullptr) {
    out->data = *data;
  }
  return true;
}

// ------------------------------------------------------------------ output

Value str(const std::string& s) { return Value::string(s); }

Value string_list(const std::vector<std::string>& items) {
  Value out = Value::array();
  for (const std::string& item : items) {
    out.push(str(item));
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
  const CollectorSession& session;
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
  out.set("stream", str(stream_name(event.stream)));
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
    return generic_envelope(
        ctx, network_call_payload(event.data, stream_name(event.stream)));
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
  CollectorSession session;
  Event event;
  if (!r.check_keys({"host", "session", "event"}) ||
      !decode_input_host(r, &host, error) ||
      !decode_session(r, &session, error)) {
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
  CollectorSession session;
  const Value* lifecycle_json = nullptr;
  if (!r.check_keys({"host", "session", "lifecycle"}) ||
      !decode_input_host(r, &host, error) ||
      !decode_session(r, &session, error) ||
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
