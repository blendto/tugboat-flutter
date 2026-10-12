// The session lifecycle state machine (docs/stateful-engine.md section 4.2)
// and app-lifecycle mapping. Pure functions over small value types, so a
// batch can be admitted against a simulated state before it is applied.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_LIFECYCLE_H
#define TUGBOAT_SESSION_ENGINE_LIFECYCLE_H

#include <optional>
#include <string>

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
// `session.start`. `engine.dispose` (without a live session) makes the
// engine `disposed`: it admits no further command.
enum class LifecycleState { kIdle, kActive, kBackground, kEnded, kDisposed };

// Flutter's AppLifecycleState, which every host maps its OS signals onto.
enum class AppState { kPaused, kHidden, kInactive, kResumed, kDetached };

enum class LifecycleSignal {
  kSessionStart,
  kSessionEnd,
  kBackgrounded,  // paused, hidden
  kForegrounded,  // resumed
  kInactive,
  kDetached,
  kDispose,  // engine.dispose
};

LifecycleState transition(LifecycleState state, LifecycleSignal signal);

// A session exists and has not ended (active or background).
bool has_live_session(LifecycleState state);

// What one app state means to the engine.
struct AppStateInfo {
  AppState state;
  const char* name;        // AppLifecycleState.name
  LifecycleSignal signal;
  const char* event_type;  // `_appLifecycleEventType`
  bool deactivates;        // tears down in-flight work
};

std::optional<AppStateInfo> parse_app_state(const std::string& name);
const AppStateInfo& app_state_info(AppState state);

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

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_LIFECYCLE_H
