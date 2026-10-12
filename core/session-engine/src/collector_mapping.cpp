#include "collector_mapping.h"

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "dart_time.h"
#include "tugboat/tb_session_engine.h"

namespace tugboat {
namespace engine {

namespace {

constexpr int64_t kInteractionSchemaVersion = 2;
constexpr int64_t kRouteChangeSchemaVersion = 2;

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
  const CollectorStamp& stamp;
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
  put_opt(&out, "sessionId", ctx.stamp.session_id);
  out.set("userId",
          ctx.stamp.user_id ? str(*ctx.stamp.user_id) : Value::null());
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
  put_opt(&out, "traitsId", ctx.stamp.traits_id);
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
  put_opt(&out, "traitsId", ctx.stamp.traits_id);
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

Value collector_event_json(const Event& event, const Host& host,
                           const CollectorStamp& stamp,
                           int64_t triggered_at_us) {
  const EnvelopeContext ctx{event, host, stamp,
                            dart_iso8601_utc(triggered_at_us)};
  return map_event(ctx);
}

Value collector_lifecycle_json(const Host& host, const LifecycleBody& in) {
  // Any eventType other than session_start is a non-start record.
  const bool is_start = in.event_type == "session_start";
  Value body = Value::object();
  body.set("sessionId", str(in.session_id));
  body.set("eventType", str(in.event_type));
  body.set("atMs", Value::integer(in.at_ms));
  body.set("triggeredAt", str(dart_iso8601_utc(in.triggered_at_us)));
  // Only session_start falls back to the configured startup user id.
  OptString user_id = in.user_id;
  if (is_start && !user_id) {
    user_id = host.configured_user_id;
  }
  body.set("userId", user_id ? str(*user_id) : Value::null());
  if (is_start) {
    add_session_start_metadata(host, in.active_locale, &body);
  }
  // A full traits bag wins over the traitsId pass-through.
  if (in.traits != nullptr) {
    body.set("traits", *in.traits);
  } else if (in.traits_id) {
    body.set("traitsId", str(*in.traits_id));
  }
  return body;
}

}  // namespace engine
}  // namespace tugboat
