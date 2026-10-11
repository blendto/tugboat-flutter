// Everything a stateful engine handle holds between messages. Commands read
// and change it in `apply`; the dispatcher alone advances `admission`.
// Later phases add their module state here. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ENGINE_STATE_H
#define TUGBOAT_SESSION_ENGINE_ENGINE_STATE_H

#include <optional>

#include "clock.h"
#include "config.h"
#include "lifecycle.h"
#include "models.h"
#include "session.h"
#include "teardown.h"

namespace tugboat {
namespace engine {

// The runtime user id. It starts as the host's `configuredUserId` (Dart
// `initialUserId ?? config.userId`) until `identity.set` takes over.
struct Identity {
  OptString user_id;
  bool set_explicitly = false;
};

struct EngineState {
  Config config;
  Admission admission;
  IdCounter ids;
  Identity identity;
  // The active app locale (Dart `_currentLocale`). Survives sessions.
  std::optional<LocaleInfo> locale;
  AppLifecycleDedupe app_lifecycle;
  // The live session, or the last one after it ended.
  std::optional<Session> session;
  Timers timers;
  Teardown teardown;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_ENGINE_STATE_H
