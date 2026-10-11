#include "session.h"

#include <utility>

#include "clock.h"
#include "dart_time.h"
#include "tugboat/tb_session_engine.h"

namespace tugboat {
namespace engine {

std::string IdCounter::next(const char* prefix) {
  return std::string(prefix) + "-" + std::to_string(next_++);
}

int64_t Session::at_ms(int64_t mono_us) const {
  return elapsed_ms(header_.start_mono_us, mono_us);
}

void Session::append(Event event, int64_t max_events) {
  events_.push_back(std::move(event));
  while (static_cast<int64_t>(events_.size()) > max_events) {
    events_.pop_front();
    truncated_ = true;
  }
}

namespace {

Value viewport_json(const SessionHeader& header) {
  Value out = Value::object();
  out.set("x", Value::number(0));
  out.set("y", Value::number(0));
  out.set("width", Value::number(header.viewport_width));
  out.set("height", Value::number(header.viewport_height));
  return out;
}

Value session_object_json(const Session& session) {
  const SessionHeader& header = session.header();
  Value out = Value::object();
  out.set("id", Value::string(header.id));
  out.set("captureSessionId", Value::string(header.id));
  put_opt(&out, "activationRequestId", header.activation_request_id);
  // `collectorSessionId` arrives with collector delivery (phase 3b).
  put_opt(&out, "explorationRunId", header.exploration_run_id);
  out.set("startedAt",
          Value::string(dart_iso8601_utc(header.started_at_wall_us)));
  out.set("platform", Value::string(header.platform));
  out.set("viewport", viewport_json(header));
  out.set("truncated", Value::boolean(session.truncated()));
  out.set("appInfo", app_info_json(header.app));
  if (session.locale()) {
    out.set("locale", locale_json(*session.locale()));
  }
  return out;
}

}  // namespace

Value session_snapshot_json(const Session& session) {
  Value out = Value::object();
  out.set("schemaVersion",
          Value::integer(TB_SESSION_ENGINE_SESSION_SCHEMA_VERSION));
  out.set("session", session_object_json(session));
  out.set("frames", Value::array());
  Value events = Value::array();
  for (const Event& event : session.events()) {
    events.push(event_json(event));
  }
  out.set("events", std::move(events));
  return out;
}

}  // namespace engine
}  // namespace tugboat
