// The stateless collector operations `collector.event` and
// `collector.sessionLifecycle`: decode a fixture-shaped input, then map it
// with collector_mapping.h, which reproduces collector_mapper.dart exactly
// (including the quirks listed in conformance/README.md and the ADR 0009
// slice 1 design notes).
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "collector_mapping.h"
#include "dart_time.h"
#include "host.h"
#include "models.h"
#include "operations.h"

namespace tugboat {
namespace engine {

namespace {

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
  const CollectorStamp stamp{session.session_id, session.user_id,
                             session.traits_id};
  *result = Value::object();
  result->set("record",
              collector_event_json(event, host, stamp, triggered_us));
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

  LifecycleBody body;
  body.event_type = event_type;
  body.session_id = *session.session_id;
  // Wall-clock difference, not clamped: may be negative.
  body.at_ms = triggered_ms - session.started_at_ms;
  body.triggered_at_us = triggered_ms * 1000;
  body.user_id = session.user_id;
  body.traits = session.traits;
  body.traits_id = session.traits_id;
  body.active_locale = active_locale;
  *result = Value::object();
  result->set("record", collector_lifecycle_json(host, body));
  return true;
}

}  // namespace engine
}  // namespace tugboat
