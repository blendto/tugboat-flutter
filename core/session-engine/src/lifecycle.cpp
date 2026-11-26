#include "lifecycle.h"

namespace tugboat {
namespace engine {

namespace {

const AppStateInfo kAppStates[] = {
    {AppState::kPaused, "paused", LifecycleSignal::kBackgrounded,
     "app_backgrounded", true},
    {AppState::kHidden, "hidden", LifecycleSignal::kBackgrounded,
     "app_backgrounded", true},
    {AppState::kInactive, "inactive", LifecycleSignal::kInactive,
     "app_inactive", false},
    {AppState::kResumed, "resumed", LifecycleSignal::kForegrounded,
     "app_foregrounded", false},
    {AppState::kDetached, "detached", LifecycleSignal::kDetached,
     "app_detached", true},
};

LifecycleState on_live(LifecycleState state, LifecycleSignal signal) {
  switch (signal) {
    case LifecycleSignal::kSessionStart: return LifecycleState::kActive;
    case LifecycleSignal::kSessionEnd:
    case LifecycleSignal::kDetached: return LifecycleState::kEnded;
    case LifecycleSignal::kBackgrounded: return LifecycleState::kBackground;
    case LifecycleSignal::kForegrounded: return LifecycleState::kActive;
    case LifecycleSignal::kInactive:
    case LifecycleSignal::kDispose: return state;
  }
  return state;
}

}  // namespace

LifecycleState transition(LifecycleState state, LifecycleSignal signal) {
  if (state == LifecycleState::kDisposed ||
      signal == LifecycleSignal::kDispose) {
    return LifecycleState::kDisposed;
  }
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

std::optional<AppStateInfo> parse_app_state(const std::string& name) {
  for (const AppStateInfo& info : kAppStates) {
    if (name == info.name) {
      return info;
    }
  }
  return std::nullopt;
}

const AppStateInfo& app_state_info(AppState state) {
  for (const AppStateInfo& info : kAppStates) {
    if (info.state == state) {
      return info;
    }
  }
  return kAppStates[0];
}

bool AppLifecycleDedupe::observe(AppState state) {
  const std::string event_type = app_state_info(state).event_type;
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

}  // namespace engine
}  // namespace tugboat
