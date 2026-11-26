// Session lifecycle messages: `session.start`, `session.end`, and
// `app.lifecycle` (docs/stateful-engine.md section 4.2). They reproduce the
// Dart controller's `start()`, `_endSession`, and `recordAppLifecycleState`
// plus the widget's `detached` handling, with change C10. Other modules join
// in through teardown stages and lifecycle hooks, not by editing this file.
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "modules.h"
#include "recorder.h"

namespace tugboat {
namespace engine {

namespace {

// The end sequence shared by `session.end`, `detached`, and a replacing
// `session.start`: tear down in-flight work, run the session-ending hooks,
// then record `session_end`.
void end_session(const ModuleRegistry& modules, Session& session, const At& at,
                 TeardownCause cause, EngineState* state, Output* out) {
  modules.run_teardown(cause, at, state, out);
  modules.run_hooks(LifecycleHookPoint::kSessionEnding, at, state, out);
  record_event(state, session,
               make_event(state, session, "session_end", at.mono_us), true,
               out);
}

// --------------------------------------------------------- session.start

struct StartInput {
  double viewport_width = 0;
  double viewport_height = 0;
  std::string platform;
  std::optional<LocaleInfo> locale;
  OptString activation_request_id;
  OptString exploration_run_id;
  int64_t session_epoch = 0;
};

class SessionStart final : public Command {
 public:
  SessionStart(StartInput input, At at) : input_(std::move(input)), at_(at) {}

  std::optional<LifecycleSignal> signal() const override {
    return LifecycleSignal::kSessionStart;
  }

  bool admit(Admission* admission, const std::string& path,
             Error* error) const override {
    if (admission->host_configured) {
      return true;
    }
    return invalid(error, path,
                   "session.start needs host metadata: send "
                   "engine.configure with `host` first");
  }

  void apply(const ModuleRegistry& modules, EngineState* state,
             Output* out) override {
    if (Session* live = state->live_session()) {
      // Change C10: a replaced session ends with `session_end` first.
      end_session(modules, *live, at_, TeardownCause::kSessionEnd, state,
                  out);
    }
    modules.run_teardown(TeardownCause::kSessionReplacement, at_, state,
                         out);
    state->app_lifecycle.reset();
    if (input_.locale) {
      state->locale = input_.locale;
    }
    Session& session = state->session.emplace(header(*state));
    session.set_locale(state->locale);
    record_event(state, session,
                 make_event(state, session, "session_start", at_.mono_us),
                 true, out);
    modules.run_hooks(LifecycleHookPoint::kSessionStarted, at_, state, out);
  }

 private:
  SessionHeader header(const EngineState& state) const {
    SessionHeader header;
    // One wall-clock reading for both (Dart reads DateTime.now() twice).
    header.id = "session-" + std::to_string(*at_.wall_us);
    header.started_at_wall_us = *at_.wall_us;
    header.start_mono_us = at_.mono_us;
    header.platform = input_.platform;
    header.viewport_width = input_.viewport_width;
    header.viewport_height = input_.viewport_height;
    header.app = state.config.host->app;
    header.activation_request_id = input_.activation_request_id;
    header.exploration_run_id = input_.exploration_run_id;
    header.session_epoch = input_.session_epoch;
    return header;
  }

  StartInput input_;
  At at_;
};

bool decode_viewport(const ObjectReader& r, StartInput* out, Error* error) {
  const Value* json = nullptr;
  if (!r.req_object("viewport", &json)) {
    return false;
  }
  const ObjectReader v(*json, r.child("viewport"), error);
  if (!v.check_keys({"width", "height"}) ||
      !v.req_double("width", &out->viewport_width) ||
      !v.req_double("height", &out->viewport_height)) {
    return false;
  }
  if (out->viewport_width < 0) {
    return v.reject("width", "must not be negative");
  }
  if (out->viewport_height < 0) {
    return v.reject("height", "must not be negative");
  }
  return true;
}

std::unique_ptr<Command> decode_start(const CommandInput& in, Error* error) {
  const ObjectReader r(in.input, in.path, error);
  StartInput start;
  if (!r.check_keys({"viewport", "platform", "locale", "activationRequestId",
                     "explorationRunId", "sessionEpoch"}) ||
      !decode_viewport(r, &start, error) ||
      !r.req_string("platform", &start.platform) ||
      !decode_locale(r.get("locale"), r.child("locale"), &start.locale,
                     error) ||
      !r.opt_string("activationRequestId", &start.activation_request_id) ||
      !r.opt_string("explorationRunId", &start.exploration_run_id) ||
      !r.req_int("sessionEpoch", &start.session_epoch)) {
    return nullptr;
  }
  if (start.session_epoch < 0) {
    r.reject("sessionEpoch", "must not be negative");
    return nullptr;
  }
  return std::make_unique<SessionStart>(std::move(start), *in.at);
}

// ----------------------------------------------------------- session.end

// Idempotent: ending an ended (or never started) session does nothing.
class SessionEnd final : public Command {
 public:
  SessionEnd(TeardownCause cause, At at) : cause_(cause), at_(at) {}

  std::optional<LifecycleSignal> signal() const override {
    return LifecycleSignal::kSessionEnd;
  }

  void apply(const ModuleRegistry& modules, EngineState* state,
             Output* out) override {
    if (Session* live = state->live_session()) {
      end_session(modules, *live, at_, cause_, state, out);
    }
  }

 private:
  TeardownCause cause_;
  At at_;
};

std::unique_ptr<Command> decode_end(const CommandInput& in, Error* error) {
  const ObjectReader r(in.input, in.path, error);
  std::optional<std::string> reason;
  if (!r.check_keys({"reason"}) || !r.opt_string("reason", &reason)) {
    return nullptr;
  }
  // Dart ends with `session_end` (endSession) or `dispose` (dispose).
  TeardownCause cause = TeardownCause::kSessionEnd;
  if (reason && *reason == "dispose") {
    cause = TeardownCause::kDispose;
  } else if (reason && *reason != "session_end") {
    r.reject("reason", "expected session_end or dispose");
    return nullptr;
  }
  return std::make_unique<SessionEnd>(cause, *in.at);
}

// --------------------------------------------------------- app.lifecycle

// Event-producing: without a live session the dispatcher drops it.
class AppLifecycle final : public Command {
 public:
  AppLifecycle(AppStateInfo info, At at) : info_(info), at_(at) {}

  std::optional<LifecycleSignal> signal() const override {
    return info_.signal;
  }

  void apply(const ModuleRegistry& modules, EngineState* state,
             Output* out) override {
    Session& session = *state->live_session();
    if (info_.deactivates) {
      modules.run_teardown(TeardownCause::kLifecycle, at_, state, out);
    }
    // Dart requests the `lifecycle` capture before it records the event.
    if (info_.signal == LifecycleSignal::kForegrounded) {
      modules.run_hooks(LifecycleHookPoint::kForegroundedBeforeRecord, at_,
                        state, out);
    }
    if (state->app_lifecycle.observe(info_.state)) {
      Event event = make_event(state, session, info_.event_type, at_.mono_us);
      event.data.set("state", Value::string(info_.name));
      record_event(state, session, std::move(event), true, out);
    }
    run_transition_hooks(modules, session, state, out);
  }

 private:
  void run_transition_hooks(const ModuleRegistry& modules, Session& session,
                            EngineState* state, Output* out) const {
    switch (info_.signal) {
      case LifecycleSignal::kBackgrounded:
        modules.run_hooks(LifecycleHookPoint::kBackgrounded, at_, state, out);
        break;
      case LifecycleSignal::kForegrounded:
        modules.run_hooks(LifecycleHookPoint::kForegrounded, at_, state, out);
        break;
      case LifecycleSignal::kDetached:
        end_session(modules, session, at_, TeardownCause::kSessionEnd, state,
                    out);
        break;
      default:
        break;
    }
  }

  AppStateInfo info_;
  At at_;
};

std::unique_ptr<Command> decode_app_lifecycle(const CommandInput& in,
                                              Error* error) {
  const ObjectReader r(in.input, in.path, error);
  std::string name;
  if (!r.check_keys({"state"}) || !r.req_string("state", &name)) {
    return nullptr;
  }
  const std::optional<AppStateInfo> info = parse_app_state(name);
  if (!info) {
    r.reject("state",
             "expected paused, hidden, inactive, resumed, or detached");
    return nullptr;
  }
  return std::make_unique<AppLifecycle>(*info, *in.at);
}

}  // namespace

void register_session_module(ModuleRegistry* registry) {
  registry->add_command("session.start",
                        {AtRule::kMonoAndWall, SessionPolicy::kAny,
                         decode_start});
  registry->add_command("session.end",
                        {AtRule::kMonoAndWall, SessionPolicy::kAny,
                         decode_end});
  registry->add_command("app.lifecycle",
                        {AtRule::kMono, SessionPolicy::kEventProducing,
                         decode_app_lifecycle});
  for (const char* type :
       {"session_start", "session_end", "app_backgrounded",
        "app_foregrounded", "app_inactive", "app_detached"}) {
    registry->add_engine_event_type(type);
  }
}

}  // namespace engine
}  // namespace tugboat
