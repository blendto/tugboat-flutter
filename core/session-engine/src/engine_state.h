// Everything a stateful engine handle holds between messages, as plain data.
// Each module owns one part; behaviour lives in the modules and the
// registry, not here. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ENGINE_STATE_H
#define TUGBOAT_SESSION_ENGINE_ENGINE_STATE_H

#include <optional>

#include "capture_seam.h"
#include "clock.h"
#include "config.h"
#include "coordination.h"
#include "delivery_state.h"
#include "frame_retention.h"
#include "interaction_state.h"
#include "lifecycle.h"
#include "models.h"
#include "navigation_state.h"
#include "session.h"

namespace tugboat {
namespace engine {

// The host identity (identity_module.cpp). The runtime user id starts as the
// host's `configuredUserId` (Dart `initialUserId ?? config.userId`) until
// `identity.set` takes over.
struct Identity {
  OptString user_id;
  bool set_explicitly = false;
  // The host's traits bag (`traits.set`). Survives sessions.
  std::optional<Value> traits;
};

class ModuleRegistry;

// The command being applied: the engine's registry, for observers that code
// deep in a module notifies (`record_event`), and the message's `at`. Set by
// the dispatcher around each `apply`; empty between messages.
struct AppliedMessage {
  const ModuleRegistry* modules = nullptr;
  std::optional<At> at;
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
  AppliedMessage applying;
  // Who still references each accepted frame's handle (section 7.6).
  FrameRetention frame_retention;
  DeliveryState delivery;
  // The capture scheduler, frame acceptance, and frame provenance.
  CaptureSeam captures;
  InteractionState interactions;
  NavigationState navigation;
  // Deferred work and the publication queue.
  Coordination coordination;

  // The session while it is live (active or background), else null.
  Session* live_session() {
    return has_live_session(lifecycle) && session ? &*session : nullptr;
  }
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_ENGINE_STATE_H
