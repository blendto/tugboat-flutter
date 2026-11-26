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

std::vector<std::string> Session::append_frame(Frame frame,
                                              int64_t max_frames) {
  frames_.push_back(std::move(frame));
  std::vector<std::string> dropped;
  while (static_cast<int64_t>(frames_.size()) > max_frames) {
    dropped.push_back(frames_.front().id);
    frames_.pop_front();
    truncated_ = true;
  }
  return dropped;
}

void Session::append_scroll_sample(ScrollSample sample, int64_t max_samples) {
  scroll_samples_.push_back(std::move(sample));
  while (static_cast<int64_t>(scroll_samples_.size()) > max_samples) {
    scroll_samples_.pop_front();
    truncated_ = true;
  }
}

namespace {

Value scroll_sample_json(const ScrollSample& sample) {
  Value out = Value::object();
  out.set("atMs", Value::integer(sample.at_ms));
  out.set("offset", Value::number(sample.offset));
  put_opt(&out, "beforeFrame", sample.before_frame);
  put_opt(&out, "afterFrame", sample.after_frame);
  put_opt(&out, "scrollableFingerprint", sample.scrollable_fingerprint);
  put_opt(&out, "axis", sample.axis);
  if (sample.offset_norm) {
    out.set("offsetNorm", Value::number(*sample.offset_norm));
  }
  return out;
}

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
  Value frames = Value::array();
  for (const Frame& frame : session.frames()) {
    frames.push(frame_json(frame));
  }
  out.set("frames", std::move(frames));
  Value events = Value::array();
  for (const Event& event : session.events()) {
    events.push(event_json(event));
  }
  out.set("events", std::move(events));
  if (!session.scroll_samples().empty()) {
    Value samples = Value::array();
    for (const ScrollSample& sample : session.scroll_samples()) {
      samples.push(scroll_sample_json(sample));
    }
    out.set("scrollSamples", std::move(samples));
  }
  return out;
}

}  // namespace engine
}  // namespace tugboat
