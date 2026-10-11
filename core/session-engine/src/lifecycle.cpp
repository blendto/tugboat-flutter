#include "lifecycle.h"

namespace tugboat {
namespace engine {

namespace {

LifecycleState on_live(LifecycleState state, LifecycleSignal signal) {
  switch (signal) {
    case LifecycleSignal::kSessionStart: return LifecycleState::kActive;
    case LifecycleSignal::kSessionEnd:
    case LifecycleSignal::kDetached: return LifecycleState::kEnded;
    case LifecycleSignal::kBackgrounded: return LifecycleState::kBackground;
    case LifecycleSignal::kForegrounded: return LifecycleState::kActive;
    case LifecycleSignal::kInactive: return state;
  }
  return state;
}

}  // namespace

LifecycleState transition(LifecycleState state, LifecycleSignal signal) {
  if (signal == LifecycleSignal::kSessionStart) {
    // From active or background this replaces the session (change C10).
    return LifecycleState::kActive;
  }
  if (has_live_session(state)) {
    return on_live(state, signal);
  }
  // Idle and ended have no session to background, resume, or end.
  return state;
}

bool has_live_session(LifecycleState state) {
  return state == LifecycleState::kActive ||
         state == LifecycleState::kBackground;
}

std::optional<AppState> parse_app_state(const std::string& name) {
  for (AppState state : {AppState::kPaused, AppState::kHidden,
                         AppState::kInactive, AppState::kResumed,
                         AppState::kDetached}) {
    if (name == app_state_name(state)) {
      return state;
    }
  }
  return std::nullopt;
}

const char* app_state_name(AppState state) {
  switch (state) {
    case AppState::kPaused: return "paused";
    case AppState::kHidden: return "hidden";
    case AppState::kInactive: return "inactive";
    case AppState::kResumed: return "resumed";
    case AppState::kDetached: return "detached";
  }
  return "inactive";
}

LifecycleSignal app_state_signal(AppState state) {
  switch (state) {
    case AppState::kPaused:
    case AppState::kHidden: return LifecycleSignal::kBackgrounded;
    case AppState::kResumed: return LifecycleSignal::kForegrounded;
    case AppState::kInactive: return LifecycleSignal::kInactive;
    case AppState::kDetached: return LifecycleSignal::kDetached;
  }
  return LifecycleSignal::kInactive;
}

const char* app_lifecycle_event_type(AppState state) {
  switch (state) {
    case AppState::kPaused:
    case AppState::kHidden: return "app_backgrounded";
    case AppState::kResumed: return "app_foregrounded";
    case AppState::kInactive: return "app_inactive";
    case AppState::kDetached: return "app_detached";
  }
  return "app_inactive";
}

bool app_state_deactivates(AppState state) {
  return state == AppState::kPaused || state == AppState::kHidden ||
         state == AppState::kDetached;
}

bool AppLifecycleDedupe::observe(AppState state) {
  const std::string event_type = app_lifecycle_event_type(state);
  const bool duplicate =
      last_state_ == state || last_event_type_ == event_type;
  last_state_ = state;
  last_event_type_ = event_type;
  return !duplicate;
}

void AppLifecycleDedupe::reset() {
  last_state_.reset();
  last_event_type_.reset();
}

bool reject_after_end(const Admission& admission, const std::string& path,
                      Error* error) {
  if (admission.lifecycle != LifecycleState::kEnded) {
    return true;
  }
  return invalid(error, path + ".type",
                 "the session has ended; start a new session first");
}

}  // namespace engine
}  // namespace tugboat
