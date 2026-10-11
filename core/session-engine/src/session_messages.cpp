// Session lifecycle messages: `session.start`, `session.end`, and
// `app.lifecycle` (docs/stateful-engine.md section 4.2). They reproduce the
// Dart controller's `start()`, `_endSession`, and `recordAppLifecycleState`
// plus the widget's `detached` handling, with changes C9 and C10.
#include <cmath>
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
// `session.start`: tear down in-flight work, then emit `session_end`.
// Collector drain (C5) joins it in phase 3b.
void end_session(EngineState* state, int64_t mono_us, TeardownCause cause,
                 Output* out) {
  state->teardown.run(cause, out);
  record_event(state, make_event(state, "session_end", mono_us), true, out);
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

  bool admit(Admission* admission, const std::string& path,
             Error* error) const override {
    if (!admission->host_configured) {
      return invalid(error, path,
                     "session.start needs host metadata: send "
                     "engine.configure with `host` first");
    }
    admission->lifecycle =
        transition(admission->lifecycle, LifecycleSignal::kSessionStart);
    return true;
  }

  void apply(const Transition& transition, EngineState* state,
             Output* out) override {
    if (has_live_session(transition.from)) {
      // Change C10: a replaced session ends with `session_end` first.
      end_session(state, at_.mono_us, TeardownCause::kSessionEnd, out);
    }
    state->teardown.run(TeardownCause::kSessionReplacement, out);
    state->app_lifecycle.reset();
    if (input_.locale) {
      state->locale = input_.locale;
    }
    state->session.emplace(header(*state));
    state->session->set_locale(state->locale);
    record_event(state, make_event(state, "session_start", at_.mono_us), true,
                 out);
    // The `initial` capture request joins here in phase 3d.
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
  if (!std::isfinite(out->viewport_width) || out->viewport_width < 0) {
    return v.reject("width", "must be finite and not negative");
  }
  if (!std::isfinite(out->viewport_height) || out->viewport_height < 0) {
    return v.reject("height", "must be finite and not negative");
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

class SessionEnd final : public Command {
 public:
  SessionEnd(TeardownCause cause, At at) : cause_(cause), at_(at) {}

  bool admit(Admission* admission, const std::string&,
             Error*) const override {
    // Idempotent: ending an ended (or never started) session does nothing.
    admission->lifecycle =
        transition(admission->lifecycle, LifecycleSignal::kSessionEnd);
    return true;
  }

  void apply(const Transition& transition, EngineState* state,
             Output* out) override {
    if (has_live_session(transition.from)) {
      end_session(state, at_.mono_us, cause_, out);
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

class AppLifecycle final : public Command {
 public:
  AppLifecycle(AppState app_state, At at) : app_state_(app_state), at_(at) {}

  bool admit(Admission* admission, const std::string& path,
             Error* error) const override {
    if (!reject_after_end(*admission, path, error)) {
      return false;
    }
    admission->lifecycle =
        transition(admission->lifecycle, app_state_signal(app_state_));
    return true;
  }

  void apply(const Transition& transition, EngineState* state,
             Output* out) override {
    if (!has_live_session(transition.from)) {
      // Dart mints the event id before `_addEvent` drops the event for want
      // of a session, so a non-duplicate state still consumes an id.
      if (state->app_lifecycle.observe(app_state_)) {
        state->ids.next("event");
      }
      return;
    }
    if (app_state_deactivates(app_state_)) {
      state->teardown.run(TeardownCause::kLifecycle, out);
    }
    if (state->app_lifecycle.observe(app_state_)) {
      Event event = make_event(state, app_lifecycle_event_type(app_state_),
                               at_.mono_us);
      event.data.set("state", Value::string(app_state_name(app_state_)));
      record_event(state, std::move(event), true, out);
    }
    if (app_state_ == AppState::kDetached) {
      end_session(state, at_.mono_us, TeardownCause::kSessionEnd, out);
    }
  }

 private:
  AppState app_state_;
  At at_;
};

std::unique_ptr<Command> decode_app_lifecycle(const CommandInput& in,
                                              Error* error) {
  const ObjectReader r(in.input, in.path, error);
  std::string name;
  if (!r.check_keys({"state"}) || !r.req_string("state", &name)) {
    return nullptr;
  }
  const std::optional<AppState> app_state = parse_app_state(name);
  if (!app_state) {
    r.reject("state",
             "expected paused, hidden, inactive, resumed, or detached");
    return nullptr;
  }
  return std::make_unique<AppLifecycle>(*app_state, *in.at);
}

}  // namespace

void register_session_messages(MessageRegistry* registry) {
  registry->add_command("session.start", AtRule::kMonoAndWall, decode_start);
  registry->add_command("session.end", AtRule::kMonoAndWall, decode_end);
  registry->add_command("app.lifecycle", AtRule::kMono, decode_app_lifecycle);
}

}  // namespace engine
}  // namespace tugboat
