#include "module_registry.h"

#include <cstdlib>
#include <utility>

namespace tugboat {
namespace engine {

void ModuleRegistry::add(const char* type, MessageSpec spec) {
  // Two modules registering one type is a programming error, caught the
  // first time any engine is created.
  if (!messages_.emplace(type, std::move(spec)).second) {
    std::abort();
  }
}

void ModuleRegistry::add_stateless(const char* type,
                                   StatelessHandler handler) {
  add(type, MessageSpec(handler));
}

void ModuleRegistry::add_query(const char* type, QueryHandler handler) {
  add(type, MessageSpec(handler));
}

void ModuleRegistry::add_command(const char* type, CommandSpec spec) {
  add(type, MessageSpec(spec));
}

const MessageSpec* ModuleRegistry::find(std::string_view type) const {
  const auto it = messages_.find(type);
  return it == messages_.end() ? nullptr : &it->second;
}

std::vector<std::string> ModuleRegistry::types() const {
  std::vector<std::string> out;
  for (const auto& entry : messages_) {
    out.push_back(entry.first);
  }
  return out;
}

void ModuleRegistry::add_teardown(TeardownStage stage,
                                  TeardownHandler handler) {
  teardown_[static_cast<size_t>(stage)].push_back(handler);
}

void ModuleRegistry::run_teardown(TeardownCause cause, EngineState* state,
                                  Output* out) const {
  for (TeardownStage stage : teardown_order(cause)) {
    for (TeardownHandler handler : teardown_[static_cast<size_t>(stage)]) {
      handler(cause, state, out);
    }
  }
}

void ModuleRegistry::add_timers(const char* prefix, TimerHandler handler) {
  if (!timers_.emplace(prefix, handler).second) {
    std::abort();
  }
}

void ModuleRegistry::fire_timer(const std::string& timer_id, const At& at,
                                EngineState* state, Output* out) const {
  if (!state->timers.take_due(timer_id, at.mono_us)) {
    return;
  }
  // The longest registered prefix owns the timer.
  const std::pair<const std::string, TimerHandler>* owner = nullptr;
  for (const auto& entry : timers_) {
    if (timer_id.rfind(entry.first, 0) == 0 &&
        (owner == nullptr || entry.first.size() > owner->first.size())) {
      owner = &entry;
    }
  }
  if (owner != nullptr) {
    owner->second(timer_id, at, state, out);
  }
}

void ModuleRegistry::add_hook(LifecycleHookPoint point, LifecycleHook hook) {
  hooks_[static_cast<size_t>(point)].push_back(hook);
}

void ModuleRegistry::on_session_started(LifecycleHook hook) {
  add_hook(LifecycleHookPoint::kSessionStarted, hook);
}

void ModuleRegistry::on_backgrounded(LifecycleHook hook) {
  add_hook(LifecycleHookPoint::kBackgrounded, hook);
}

void ModuleRegistry::on_foregrounded(LifecycleHook hook) {
  add_hook(LifecycleHookPoint::kForegrounded, hook);
}

void ModuleRegistry::on_session_ending(LifecycleHook hook) {
  add_hook(LifecycleHookPoint::kSessionEnding, hook);
}

void ModuleRegistry::run_hooks(LifecycleHookPoint point, const At& at,
                               EngineState* state, Output* out) const {
  for (LifecycleHook hook : hooks_[static_cast<size_t>(point)]) {
    hook(at, state, out);
  }
}

void ModuleRegistry::on_frame_accepted(FrameAcceptedHook hook) {
  frame_accepted_.push_back(hook);
}

void ModuleRegistry::run_frame_accepted(const Frame& frame,
                                        const std::string& handle,
                                        EngineState* state,
                                        Output* out) const {
  for (FrameAcceptedHook hook : frame_accepted_) {
    hook(frame, handle, state, out);
  }
}

void ModuleRegistry::add_engine_event_type(const char* type) {
  engine_event_types_.insert(type);
}

bool ModuleRegistry::is_engine_event_type(const std::string& type) const {
  return engine_event_types_.count(type) != 0;
}

}  // namespace engine
}  // namespace tugboat
