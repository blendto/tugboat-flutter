// The clock model (docs/stateful-engine.md section 5): fact time stamps on
// messages, `atMs` derivation, and host timers. The engine never reads a
// clock; time arrives with messages and timers are effects.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CLOCK_H
#define TUGBOAT_SESSION_ENGINE_CLOCK_H

#include <cstdint>
#include <map>
#include <optional>
#include <string>

#include "json.h"
#include "output.h"
#include "reader.h"

namespace tugboat {
namespace engine {

// `at`: when the fact happened. `mono_us` is the host monotonic clock in
// microseconds (non-negative); `wall_us` is UTC epoch microseconds in Dart's
// DateTime range.
struct At {
  int64_t mono_us = 0;
  std::optional<int64_t> wall_us;
};

// Which `at` fields a message type requires.
enum class AtRule {
  kNone,         // no `at` allowed (configuration, queries, stateless)
  kMono,         // `at.monoUs` required, `at.wallUs` optional
  kMonoAndWall,  // both required
};

// Decodes `at` (nullptr when absent) at JSON path `path` per `rule`.
bool decode_at(const Value* json, AtRule rule, const std::string& path,
               std::optional<At>* out, Error* error);

// Decodes an optional non-negative monotonic time stamp field.
bool decode_mono_us(const ObjectReader& r, const char* key,
                    std::optional<int64_t>* out);

// Event `atMs`: `floor((fact_mono_us - start_mono_us) / 1000)`, which is
// Dart's `Stopwatch.elapsedMilliseconds`. A fact stamped before the session
// started gets 0: one monotonic clock means `atMs` is never negative
// (change C1).
int64_t elapsed_ms(int64_t start_mono_us, int64_t fact_mono_us);

struct EngineState;

// A module that owns timers. It is called back when its timer fires.
class TimerOwner {
 public:
  virtual ~TimerOwner() = default;
  virtual void on_timer_fired(const std::string& timer_id, const At& at,
                              EngineState* state, Output* out) = 0;
};

// Host timers, keyed by a stable timer id. Each armed timer remembers its
// owner, so `timer.fired` is routed to the module that scheduled it.
class Timers {
 public:
  // Arms (or re-arms) `timer_id` and emits `timer.schedule`.
  void schedule(const std::string& timer_id, int64_t at_mono_us,
                TimerOwner* owner, Output* out);
  // Disarms `timer_id` and emits `timer.cancel` when it was armed.
  void cancel(const std::string& timer_id, Output* out);
  // Disarms `timer_id` and returns its owner when it is armed and due at
  // `now_mono_us`. Returns nullptr for an unknown id, a cancelled timer, or a
  // stale fire stamped before the current deadline (a host fire of a timer
  // that was re-armed later); those are ignored (principle 4).
  TimerOwner* take_due(const std::string& timer_id, int64_t now_mono_us);
  bool armed(const std::string& timer_id) const;

 private:
  struct Armed {
    int64_t at_mono_us = 0;
    TimerOwner* owner = nullptr;
  };
  std::map<std::string, Armed> armed_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CLOCK_H
