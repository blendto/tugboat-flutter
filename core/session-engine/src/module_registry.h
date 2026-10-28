// The module registry: everything an engine module contributes, collected
// once at startup (`modules.h`). A module registers its message types, the
// teardown work it owns per stage, the timers it owns (by id prefix),
// lifecycle hooks, and the event types it records itself. Modules live in
// their own files, so phases add behaviour without editing shared code.
//
// Three kinds of message:
// - stateless: the slice 2 operations; respond with `result`.
// - query: reads engine state; responds with `result` (`session.snapshot`).
// - command: changes engine state; responds with `records` and `effects`.
//   Commands go through decode, admit, and apply, so a `batch` is validated
//   as a whole before any of it is applied.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_MODULE_REGISTRY_H
#define TUGBOAT_SESSION_ENGINE_MODULE_REGISTRY_H

#include <array>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

#include "clock.h"
#include "engine_state.h"
#include "json.h"
#include "lifecycle.h"
#include "output.h"
#include "reader.h"
#include "teardown.h"

namespace tugboat {
namespace engine {

class ModuleRegistry;

// The part of engine state that decides whether a message is accepted. A
// batch is admitted against a simulated copy before anything is applied.
struct Admission {
  LifecycleState lifecycle = LifecycleState::kIdle;
  bool host_configured = false;
};

// A decoded command. Decoding never reads engine state; `admit` checks the
// command against the admission state it will see; `apply` cannot fail.
class Command {
 public:
  virtual ~Command() = default;

  // The lifecycle signal this command sends. The dispatcher advances the
  // lifecycle after `apply`, so `apply` sees the state before the command.
  virtual std::optional<LifecycleSignal> signal() const {
    return std::nullopt;
  }

  // State-dependent checks beyond the type's session policy. May record what
  // the command changes for later messages of the same batch. `path` is the
  // message's JSON path (`$` or `$.messages[i]`).
  virtual bool admit(Admission* /*admission*/, const std::string& /*path*/,
                     Error* /*error*/) const {
    return true;
  }

  virtual void apply(const ModuleRegistry& modules, EngineState* state,
                     Output* out) = 0;
};

// What a command decoder sees: the message `input` object, its JSON path,
// and the decoded `at` (present unless the type's rule is kNone/kOptional).
struct CommandInput {
  const Value& input;
  std::string path;
  std::optional<At> at;
};

// Whether a command needs a live session.
enum class SessionPolicy {
  kAny,
  // An event-producing fact. Without a live session (before the first
  // session, or after `session_end`, change C9) it is accepted and dropped:
  // the dispatcher does not apply it.
  kEventProducing,
};

using StatelessHandler = bool (*)(const Value& input, Value* result,
                                  Error* error);
using QueryHandler = bool (*)(const EngineState& state, const Value& input,
                              const std::string& path, Value* result,
                              Error* error);
// Returns nullptr and fills `error` when the input is invalid.
using CommandDecoder = std::unique_ptr<Command> (*)(const CommandInput& input,
                                                    Error* error);

struct CommandSpec {
  AtRule at = AtRule::kNone;
  SessionPolicy policy = SessionPolicy::kAny;
  CommandDecoder decode = nullptr;
};

using MessageSpec = std::variant<StatelessHandler, QueryHandler, CommandSpec>;

// Lifecycle points modules can hook, in the order they were registered.
enum class LifecycleHookPoint {
  kSessionStarted,  // after `session_start` is recorded
  kBackgrounded,    // after `paused` / `hidden` teardown
  kForegrounded,    // on `resumed`
  kSessionEnding,   // after end teardown, before `session_end` is recorded
  // On `resumed`, before `app_foregrounded` is recorded (Dart requests the
  // `lifecycle` capture first).
  kForegroundedBeforeRecord,
};

constexpr size_t kLifecycleHookPointCount = 5;

using TeardownHandler = void (*)(TeardownCause cause, const At& at,
                                 EngineState* state, Output* out);
using TimerHandler = void (*)(const std::string& timer_id, const At& at,
                              EngineState* state, Output* out);
using LifecycleHook = void (*)(const At& at, EngineState* state, Output* out);
// Runs after every applied command, in registration order (deferred work,
// coordination.h).
using AfterCommandHook = void (*)(const At& at, EngineState* state,
                                  Output* out);
// A frame was accepted into the live session; its frame record is already
// in `out`. `handle` names the frame's bytes in the host. Collector delivery
// (phase 3b) uses it to queue the frame lane and hold the handle.
using FrameAcceptedHook = void (*)(const Frame& frame,
                                   const std::string& handle,
                                   EngineState* state, Output* out);
// Sees every event record right after the recorder emits it (recorder.cpp),
// in record order. Collector delivery queues events this way, so it sees
// exactly what every other record consumer sees (design principle 5).
using EventObserver = void (*)(const EventRecord& record, const At& at,
                               EngineState* state, Output* out);

class ModuleRegistry {
 public:
  // Messages. Registering a type twice is a programming error (abort).
  void add_stateless(const char* type, StatelessHandler handler);
  void add_query(const char* type, QueryHandler handler);
  void add_command(const char* type, CommandSpec spec);
  // nullptr for an unknown type.
  const MessageSpec* find(std::string_view type) const;
  // Every registered message type, sorted.
  std::vector<std::string> types() const;

  // In-flight work torn down per stage, run in `teardown_order(cause)`.
  void add_teardown(TeardownStage stage, TeardownHandler handler);
  void run_teardown(TeardownCause cause, const At& at, EngineState* state,
                    Output* out) const;

  // Timers whose ids start with `prefix` are routed to `handler`.
  void add_timers(const char* prefix, TimerHandler handler);
  // Routes a due timer to its owner. Unknown, cancelled, and stale fires
  // are ignored.
  void fire_timer(const std::string& timer_id, const At& at,
                  EngineState* state, Output* out) const;

  void on_session_started(LifecycleHook hook);
  void on_backgrounded(LifecycleHook hook);
  void on_foregrounded(LifecycleHook hook);
  void on_session_ending(LifecycleHook hook);
  void on_foregrounded_before_record(LifecycleHook hook);
  void run_hooks(LifecycleHookPoint point, const At& at, EngineState* state,
                 Output* out) const;

  // Frame acceptance, in registration order. Whoever accepts a frame runs
  // these after emitting its frame record.
  void on_frame_accepted(FrameAcceptedHook hook);
  void run_frame_accepted(const Frame& frame, const std::string& handle,
                          EngineState* state, Output* out) const;

  // After every applied command, in registration order.
  void on_after_command(AfterCommandHook hook);
  void run_after_command(const At& at, EngineState* state, Output* out) const;

  // Event record observers, in registration order.
  void on_event_recorded(EventObserver observer);
  void notify_event_recorded(const EventRecord& record, const At& at,
                             EngineState* state, Output* out) const;

  // Event types the engine records itself; adapters cannot record them.
  void add_engine_event_type(const char* type);
  bool is_engine_event_type(const std::string& type) const;

 private:
  void add(const char* type, MessageSpec spec);
  void add_hook(LifecycleHookPoint point, LifecycleHook hook);

  std::map<std::string, MessageSpec, std::less<>> messages_;
  std::array<std::vector<TeardownHandler>, kTeardownStageCount> teardown_;
  std::map<std::string, TimerHandler> timers_;
  std::array<std::vector<LifecycleHook>, kLifecycleHookPointCount> hooks_;
  std::vector<FrameAcceptedHook> frame_accepted_;
  std::vector<AfterCommandHook> after_command_;
  std::vector<EventObserver> event_observers_;
  std::set<std::string> engine_event_types_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_MODULE_REGISTRY_H
