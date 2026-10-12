// What a stateful message produces: records (things that happened, in append
// order) and effects (things the host must do, in order). Typed here; JSON
// only in `records_json` / `effects_json` at the response boundary.
// See docs/stateful-engine.md section 3. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_OUTPUT_H
#define TUGBOAT_SESSION_ENGINE_OUTPUT_H

#include <cstdint>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "json.h"
#include "models.h"

namespace tugboat {
namespace engine {

// ----------------------------------------------------------------- records

// `{"kind": "event", "event": TugboatEvent.toJson(), "userId": …}`. `userId`
// is the runtime user id when the event was recorded (stamped at record
// time, design section 7.2); null when none is set.
struct EventRecord {
  Event event;
  OptString user_id;
};

// `{"kind": "frame", "handle": …, "frame": TugboatFrame.toJson()}`: a frame
// accepted into the session. The host keeps its bytes under `handle`.
struct FrameRecord {
  std::string handle;
  Frame frame;
};

// `{"kind": "health", "component": …, "counters": {name: count}}`: a change
// to the engine's bounded health counters for one component.
struct HealthRecord {
  std::string component;
  std::vector<std::pair<std::string, int64_t>> counters;
};

using Record = std::variant<EventRecord, FrameRecord, HealthRecord>;

// ----------------------------------------------------------------- effects

// `timer.schedule {timerId, atMonoUs}`: (re)arm the host timer `timer_id` to
// fire at host monotonic time `at_mono_us`; an armed timer with the same id
// is replaced. The host answers with `timer.fired`.
struct TimerSchedule {
  std::string timer_id;
  int64_t at_mono_us = 0;
};

// `timer.cancel {timerId}`: disarm the host timer. No answer.
struct TimerCancel {
  std::string timer_id;
};

enum class HttpLane { kLifecycle, kEvents, kFrames };

// One multipart part whose bytes the host resolves from a frame handle.
struct MultipartFrame {
  std::string handle;
  std::string filename;
};

// `multipart {fields, frames}`. `fields` are `[name, value]` string pairs in
// wire order. `frames` are the file parts (form field `files`), in wire
// order; the host resolves each part's bytes from its handle.
struct MultipartBody {
  std::vector<std::pair<std::string, std::string>> fields;
  std::vector<MultipartFrame> frames;
};

// A JSON request body, already encoded: the exact UTF-8 text to put on the
// wire (byte-identical to Dart's `jsonEncode`). Hosts never re-encode it.
struct JsonBody {
  std::string text;
};

// `http.send {requestId, lane, path, timeoutMs, jsonBody | multipart}`.
// `requestId` is a string (`http-N`); the host answers with
// `transport.result {requestId, …}` echoing it.
struct HttpSend {
  std::string request_id;
  HttpLane lane = HttpLane::kEvents;
  std::string path;
  int64_t timeout_ms = 0;
  std::variant<JsonBody, MultipartBody> body;
};

// `frame.release {handle}`: the host may drop the frame's bytes. No answer.
struct FrameRelease {
  std::string handle;
};

// What a capture request was made for (design section 8.2).
struct CaptureContext {
  int64_t route_epoch = 0;
  OptString navigator_id;
  OptString route_instance_id;
  int64_t boundary_generation = 0;
};

// `capture.request {…}`: capture one frame. The host or adapter answers with
// `capture.result {requestId, …}`.
struct CaptureRequest {
  std::string request_id;
  FrameTrigger trigger = FrameTrigger::kManual;
  bool force = false;
  bool require_fresh_paint = false;
  bool drop_when_busy = false;
  int64_t not_before_mono_us = 0;
  CaptureContext context;
  OptString dhash_baseline;
  double scale = 1.0;
};

using Effect = std::variant<TimerSchedule, TimerCancel, HttpSend,
                            FrameRelease, CaptureRequest>;

struct Output {
  std::vector<Record> records;
  std::vector<Effect> effects;
};

const char* http_lane_name(HttpLane lane);

Value records_json(const std::vector<Record>& records);
Value effects_json(const std::vector<Effect>& effects);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_OUTPUT_H
