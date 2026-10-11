// What a stateful message produces: records (things that happened, in append
// order) and effects (things the host must do, in order). Typed here; JSON
// only in `records_json` / `effects_json` at the response boundary.
// See docs/stateful-engine.md section 3. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_OUTPUT_H
#define TUGBOAT_SESSION_ENGINE_OUTPUT_H

#include <cstdint>
#include <string>
#include <variant>
#include <vector>

#include "json.h"
#include "models.h"

namespace tugboat {
namespace engine {

// `{"kind": "event", "event": TugboatEvent.toJson(), "userId": …}`. `userId`
// is the runtime user id when the event was recorded (stamped at record
// time, design section 7.2); null when none is set.
struct EventRecord {
  Event event;
  OptString user_id;
};

// Later phases add frame and health records as further alternatives.
using Record = std::variant<EventRecord>;

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

// Later phases add `http.send`, `frame.release`, and `capture.request`.
using Effect = std::variant<TimerSchedule, TimerCancel>;

struct Output {
  std::vector<Record> records;
  std::vector<Effect> effects;
};

Value records_json(const std::vector<Record>& records);
Value effects_json(const std::vector<Effect>& effects);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_OUTPUT_H
