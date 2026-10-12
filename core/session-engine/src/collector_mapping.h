// Typed collector record mapping: collector_mapper.dart (and the `toJson` of
// the Dart models it calls), reproduced exactly. The stateless operations
// (`collector.event`, `collector.sessionLifecycle`, collector.cpp) and the
// stateful delivery lanes both build their wire bodies here, so there is one
// mapping. Changing any output here is a wire contract change.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_COLLECTOR_MAPPING_H
#define TUGBOAT_SESSION_ENGINE_COLLECTOR_MAPPING_H

#include <cstdint>
#include <optional>
#include <string>

#include "host.h"
#include "json.h"
#include "models.h"

namespace tugboat {
namespace engine {

// What `mapTugboatEventToCollectorEvent` stamps besides the event itself.
// An absent `session_id` or `traits_id` is omitted; `user_id` is always
// written (null when absent).
struct CollectorStamp {
  OptString session_id;
  OptString user_id;
  OptString traits_id;
};

// `mapTugboatEventToCollectorEvent`: one `/v1/events/batch` element.
// `triggered_at_us` is `sessionStartedAt.add(Duration(milliseconds: atMs))`
// in epoch microseconds.
Value collector_event_json(const Event& event, const Host& host,
                           const CollectorStamp& stamp,
                           int64_t triggered_at_us);

// The inputs of `mapTugboatSessionLifecycleToCollectorSession`. `at_ms` is
// the body's `atMs`: Dart computes it from wall clocks
// (`triggeredAt.difference(sessionStartedAt)`); the stateful engine passes
// the monotonic difference (change C1).
struct LifecycleBody {
  std::string event_type;
  std::string session_id;
  int64_t at_ms = 0;
  int64_t triggered_at_us = 0;
  OptString user_id;
  const Value* traits = nullptr;  // a full traits object wins over traitsId
  OptString traits_id;
  std::optional<LocaleInfo> active_locale;
};

// `mapTugboatSessionLifecycleToCollectorSession`: a `/v1/sessions` body.
Value collector_lifecycle_json(const Host& host, const LifecycleBody& body);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_COLLECTOR_MAPPING_H
