#include "session.h"

#include <utility>

#include "clock.h"
#include "dart_time.h"
#include "text.h"
#include "tugboat/tb_session_engine.h"

namespace tugboat {
namespace engine {

std::string IdCounter::next(const char* prefix) {
  int64_t number = 0;
  return next(prefix, &number);
}

std::string IdCounter::next(const char* prefix, int64_t* number) {
  *number = next_++;
  return std::string(prefix) + "-" + std::to_string(*number);
}

std::string format_uuid_v4(const std::array<uint8_t, 16>& in) {
  std::array<uint8_t, 16> bytes = in;
  bytes[6] = static_cast<uint8_t>((bytes[6] & 0x0f) | 0x40);
  bytes[8] = static_cast<uint8_t>((bytes[8] & 0x3f) | 0x80);
  static const char kHex[] = "0123456789abcdef";
  std::string out;
  out.reserve(36);
  for (size_t i = 0; i < bytes.size(); ++i) {
    if (i == 4 || i == 6 || i == 8 || i == 10) {
      out.push_back('-');
    }
    out.push_back(kHex[bytes[i] >> 4]);
    out.push_back(kHex[bytes[i] & 0x0f]);
  }
  return out;
}

void IdCounter::begin_session(const std::array<uint8_t, 32>& seed) {
  seed_ = seed;
  stream_ = 0;
}

std::string IdCounter::next_uuid_id(const char* prefix) {
  // SHA-256(seed || big-endian stream index): 16 of its 32 bytes feed the
  // UUID, so ids neither repeat nor reveal the seed.
  std::string input(seed_.begin(), seed_.end());
  for (int shift = 56; shift >= 0; shift -= 8) {
    input.push_back(static_cast<char>((stream_ >> shift) & 0xff));
  }
  ++stream_;
  const std::array<uint8_t, 32> digest = sha256(input);
  std::array<uint8_t, 16> bytes;
  for (size_t i = 0; i < bytes.size(); ++i) {
    bytes[i] = digest[i];
  }
  return std::string(prefix) + "-" + format_uuid_v4(bytes);
}

std::string IdCounter::next_session_id() { return next_uuid_id("session"); }

std::string IdCounter::next_id(const char* prefix) {
  return next_uuid_id(prefix);
}

std::string IdCounter::next_event() {
  return next_uuid_id("event");
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
  // Never `collectorSessionId`: as Dart's sink, delivery keeps the
  // collector's session id to itself (`DeliveryState::ids`).
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
