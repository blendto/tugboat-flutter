// Engine-level messages: `engine.configure`, `session.snapshot`, and
// `timer.fired` (docs/stateful-engine.md sections 3, 6, and 10).
#include <memory>
#include <string>
#include <utility>

#include "config.h"
#include "modules.h"
#include "session.h"

namespace tugboat {
namespace engine {

namespace {

// `engine.configure`: replaces the configuration. Sent before the first
// session and again only between sessions.
class Configure final : public Command {
 public:
  explicit Configure(Config config) : config_(std::move(config)) {}

  bool admit(Admission* admission, const std::string& path,
             Error* error) const override {
    if (has_live_session(admission->lifecycle)) {
      return invalid(error, path + ".type",
                     "engine.configure is only accepted between sessions");
    }
    admission->host_configured = config_.host.has_value();
    return true;
  }

  void apply(const ModuleRegistry&, EngineState* state, Output*) override {
    if (config_.host && !state->identity.set_explicitly) {
      state->identity.user_id = config_.host->configured_user_id;
    }
    state->config = std::move(config_);
  }

 private:
  Config config_;
};

std::unique_ptr<Command> decode_configure(const CommandInput& in,
                                          Error* error) {
  Config config;
  if (!decode_config(in.input, in.path, &config, error)) {
    return nullptr;
  }
  return std::make_unique<Configure>(std::move(config));
}

// `timer.fired {timerId}`: routed by timer-id prefix to the module that
// armed it. Unknown, cancelled, and stale timer ids are ignored.
class TimerFired final : public Command {
 public:
  TimerFired(std::string timer_id, At at)
      : timer_id_(std::move(timer_id)), at_(at) {}

  void apply(const ModuleRegistry& modules, EngineState* state,
             Output* out) override {
    modules.fire_timer(timer_id_, at_, state, out);
  }

 private:
  std::string timer_id_;
  At at_;
};

std::unique_ptr<Command> decode_timer_fired(const CommandInput& in,
                                            Error* error) {
  const ObjectReader r(in.input, in.path, error);
  std::string timer_id;
  if (!r.check_keys({"timerId"}) || !r.req_string("timerId", &timer_id)) {
    return nullptr;
  }
  if (timer_id.empty()) {
    r.reject("timerId", "must not be empty");
    return nullptr;
  }
  return std::make_unique<TimerFired>(std::move(timer_id), *in.at);
}

// `session.snapshot {}` → `{"snapshot": TugboatSession.toJson() | null}`:
// the live session, or the last one after it ended; null before the first.
bool run_snapshot(const EngineState& state, const Value& input,
                  const std::string& path, Value* result, Error* error) {
  const ObjectReader r(input, path, error);
  if (!r.check_keys({})) {
    return false;
  }
  *result = Value::object();
  result->set("snapshot", state.session ? session_snapshot_json(*state.session)
                                        : Value::null());
  return true;
}

}  // namespace

void register_engine_module(ModuleRegistry* registry) {
  registry->add_command("engine.configure",
                        {AtRule::kOptional, SessionPolicy::kAny,
                         decode_configure});
  registry->add_command("timer.fired",
                        {AtRule::kMono, SessionPolicy::kAny,
                         decode_timer_fired});
  registry->add_query("session.snapshot", run_snapshot);
}

}  // namespace engine
}  // namespace tugboat
