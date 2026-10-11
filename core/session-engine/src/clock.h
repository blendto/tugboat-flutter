// The clock model (docs/stateful-engine.md section 5): fact time stamps on
// messages, `atMs` derivation, and host timer deadlines. The engine never
// reads a clock; time arrives with messages and timers are effects.
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
  kNone,         // no `at` allowed (stateless operations)
  kOptional,     // `at` may be sent and is validated, but not used
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
// started records 0 (change C13: an asynchronous seam can deliver such facts
// late).
int64_t elapsed_ms(int64_t start_mono_us, int64_t fact_mono_us);

// Deadlines of the host timers the engine has armed, keyed by timer id. A
// timer id starts with the prefix of the module that owns it; the module
// registry routes `timer.fired` by that prefix.
class Timers {
 public:
  // Arms (or re-arms) `timer_id` and emits `timer.schedule`.
  void schedule(const std::string& timer_id, int64_t at_mono_us, Output* out);
  // Disarms `timer_id` and emits `timer.cancel` when it was armed.
  void cancel(const std::string& timer_id, Output* out);
  // Disarms `timer_id` and returns true when it is armed and due at
  // `now_mono_us`. False for an unknown id, a cancelled timer, or a stale
  // fire stamped before the current deadline (a host fire of a timer that
  // was re-armed later); those are ignored (principle 4).
  bool take_due(const std::string& timer_id, int64_t now_mono_us);
  bool armed(const std::string& timer_id) const;

 private:
  std::map<std::string, int64_t> deadlines_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CLOCK_H
