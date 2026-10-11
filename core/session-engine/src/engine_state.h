// Everything a stateful engine handle holds between messages, as plain data.
// Each module owns one part; behaviour lives in the modules and the
// registry, not here. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ENGINE_STATE_H
#define TUGBOAT_SESSION_ENGINE_ENGINE_STATE_H

#include <optional>

#include "clock.h"
#include "config.h"
#include "delivery_state.h"
#include "interaction_state.h"
#include "lifecycle.h"
#include "models.h"
#include "navigation_state.h"
#include "session.h"

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
  LifecycleState lifecycle = LifecycleState::kIdle;
  IdCounter ids;
  Identity identity;
  // The active app locale (Dart `_currentLocale`). Survives sessions.
  std::optional<LocaleInfo> locale;
  AppLifecycleDedupe app_lifecycle;
  // The live session, or the last one after it ended.
  std::optional<Session> session;
  Timers timers;
  DeliveryState delivery;
  InteractionState interactions;
  NavigationState navigation;

  // The session while it is live (active or background), else null.
  Session* live_session() {
    return has_live_session(lifecycle) && session ? &*session : nullptr;
  }
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_ENGINE_STATE_H
