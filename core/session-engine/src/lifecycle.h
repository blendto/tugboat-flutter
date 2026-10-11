// The session lifecycle state machine (docs/stateful-engine.md section 4.2)
// and app-lifecycle event mapping. Pure functions over small value types, so
// a batch can be admitted against a simulated state before it is applied.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_LIFECYCLE_H
#define TUGBOAT_SESSION_ENGINE_LIFECYCLE_H

#include <optional>
#include <string>

#include "reader.h"

namespace tugboat {
namespace engine {

//          session.start            app.lifecycle(paused|hidden)
//   idle ───────────────────► active ◄──────────────────────────► background
//    ▲                          │      app.lifecycle(resumed)        │
//    │                          │ session.end / detached             │
//    │                          ▼                                    │
//    └─────────────────────── ended ◄────────────────────────────────┘
//
// `ended` keeps the last session for `session.snapshot` until the next
// `session.start`. Phase 3b inserts `ending` (the delivery drain) before
// `ended`.
enum class LifecycleState { kIdle, kActive, kBackground, kEnded };

// Flutter's AppLifecycleState, which every host maps its OS signals onto.
enum class AppState { kPaused, kHidden, kInactive, kResumed, kDetached };

enum class LifecycleSignal {
  kSessionStart,
  kSessionEnd,
  kBackgrounded,  // paused, hidden
  kForegrounded,  // resumed
  kInactive,
  kDetached,
};

LifecycleState transition(LifecycleState state, LifecycleSignal signal);

// A session exists and has not ended (active or background).
bool has_live_session(LifecycleState state);

std::optional<AppState> parse_app_state(const std::string& name);
const char* app_state_name(AppState state);
LifecycleSignal app_state_signal(AppState state);
// `_appLifecycleEventType`: app_backgrounded / app_foregrounded /
// app_inactive / app_detached.
const char* app_lifecycle_event_type(AppState state);
// paused, hidden, and detached tear down in-flight work.
bool app_state_deactivates(AppState state);

// Dart `recordAppLifecycleState` dedupe: a state equal to the previous state,
// or one mapping to the same event type, emits nothing. Both are remembered
// either way. Reset at session start.
class AppLifecycleDedupe {
 public:
  // True when `state` emits an event; records it as the latest state.
  bool observe(AppState state);
  void reset();

 private:
  std::optional<AppState> last_state_;
  std::optional<std::string> last_event_type_;
};

// The part of engine state that decides whether a message is accepted.
// Batches are admitted against a copy before anything is applied.
struct Admission {
  LifecycleState lifecycle = LifecycleState::kIdle;
  bool host_configured = false;
};

// The lifecycle change one command makes, computed during admission.
struct Transition {
  LifecycleState from = LifecycleState::kIdle;
  LifecycleState to = LifecycleState::kIdle;
};

// Change C9: after `session_end`, event-producing messages are
// `invalid_message`. `path` is the message's JSON path.
bool reject_after_end(const Admission& admission, const std::string& path,
                      Error* error);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_LIFECYCLE_H
