#include "engine.h"

#include <memory>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "tugboat/tb_session_engine.h"

namespace tugboat {
namespace engine {

namespace {

// A decoded command, the JSON path of its message, and what admission
// decided for it.
struct Pending {
  std::unique_ptr<Command> command;
  std::string path;
  SessionPolicy policy = SessionPolicy::kAny;
  // The lifecycle state the command sees when it is applied, and the one it
  // leaves (what the work it deferred sees).
  LifecycleState lifecycle = LifecycleState::kIdle;
  LifecycleState lifecycle_after = LifecycleState::kIdle;
  // An event-producing fact without a live session: accepted, not applied.
  bool dropped = false;
  // When the fact happened (absent on untimed messages).
  std::optional<At> at;
};

bool check_contract(const ObjectReader& envelope, Error* error) {
  const Value* contract = nullptr;
  if (!envelope.opt_object("contract", &contract)) {
    return false;
  }
  if (contract == nullptr) {
    return true;
  }
  const ObjectReader r(*contract, envelope.child("contract"), error);
  int64_t session_schema = 0;
  int64_t fingerprint_schema = 0;
  if (!r.check_keys({"sessionSchemaVersion", "fingerprintSchemaVersion"}) ||
      !r.req_int("sessionSchemaVersion", &session_schema) ||
      !r.req_int("fingerprintSchemaVersion", &fingerprint_schema)) {
    return false;
  }
  if (session_schema != TB_SESSION_ENGINE_SESSION_SCHEMA_VERSION ||
      fingerprint_schema != TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION) {
    return fail(error, TB_SESSION_CONTRACT_MISMATCH, envelope.child("contract"),
                "engine implements sessionSchemaVersion " +
                    std::to_string(TB_SESSION_ENGINE_SESSION_SCHEMA_VERSION) +
                    " and fingerprintSchemaVersion " +
                    std::to_string(
                        TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION));
  }
  return true;
}

bool unsupported(const ObjectReader& envelope, Error* error) {
  return fail(error, TB_SESSION_UNSUPPORTED_MESSAGE, envelope.child("type"),
              "unknown message type");
}

bool decode_command(const ObjectReader& envelope, const CommandSpec& spec,
                    Pending* out, Error* error) {
  std::optional<At> at;
  const Value* input = nullptr;
  if (!decode_at(envelope.get("at"), spec.at, envelope.child("at"), &at,
                 error) ||
      !envelope.req_object("input", &input)) {
    return false;
  }
  // Dart's `jsonEncode` throws on NaN and infinities, so no state-changing
  // message may carry one (`1e400`), whether or not it reaches the output.
  std::string bad_path;
  if (!all_finite(*input, envelope.child("input"), &bad_path)) {
    return invalid(error, bad_path, "non-finite number cannot be encoded");
  }
  const CommandInput command_input{*input, envelope.child("input"), at};
  out->command = spec.decode(command_input, error);
  out->at = at;
  out->path = envelope.path();
  out->policy = spec.policy;
  return out->command != nullptr;
}

// One element of `batch.messages`: only commands can be batched.
bool decode_batched(const ModuleRegistry& modules, const Value& message,
                    const std::string& path, Pending* out, Error* error) {
  if (!message.is_object()) {
    return invalid(error, path, "expected object");
  }
  const ObjectReader envelope(message, path, error);
  std::string type;
  if (!envelope.req_string("type", &type)) {
    return false;
  }
  if (type == "batch") {
    return invalid(error, envelope.child("type"), "batches cannot nest");
  }
  if (!envelope.check_keys({"type", "contract", "at", "input"}) ||
      !check_contract(envelope, error)) {
    return false;
  }
  const MessageSpec* spec = modules.find(type);
  if (spec == nullptr) {
    return unsupported(envelope, error);
  }
  const CommandSpec* command = std::get_if<CommandSpec>(spec);
  if (command == nullptr) {
    return invalid(error, envelope.child("type"),
                   "only state-changing messages can be batched");
  }
  return decode_command(envelope, *command, out, error);
}

Value command_response(const std::string& type, const Output& out) {
  Value response = Value::object();
  response.set("type", Value::string(type));
  response.set("records", records_json(out.records));
  response.set("effects", effects_json(out.effects));
  return response;
}

Value result_response(const std::string& type, Value result) {
  Value response = Value::object();
  response.set("type", Value::string(type));
  response.set("result", std::move(result));
  response.set("effects", Value::array());
  return response;
}

class Dispatch {
 public:
  Dispatch(const ModuleRegistry& modules, EngineState* state, Error* error)
      : modules_(modules), state_(state), error_(error) {}

  bool message(const Value& message, Value* response) {
    if (!message.is_object()) {
      return invalid(error_, "$", "expected object");
    }
    const ObjectReader envelope(message, "$", error_);
    std::string type;
    if (!envelope.check_keys({"type", "contract", "at", "input", "messages"}) ||
        !envelope.req_string("type", &type) ||
        !check_contract(envelope, error_)) {
      return false;
    }
    if (type == "batch") {
      return batch(envelope, response);
    }
    if (envelope.get("messages") != nullptr) {
      return invalid(error_, envelope.child("messages"), "unknown key");
    }
    const MessageSpec* spec = modules_.find(type);
    if (spec == nullptr) {
      return unsupported(envelope, error_);
    }
    return std::visit(
        [&](const auto& handler) {
          return run(envelope, type, handler, response);
        },
        *spec);
  }

 private:
  // Stateless operations take no `at`.
  bool run(const ObjectReader& envelope, const std::string& type,
           StatelessHandler handler, Value* response) {
    const Value* input = nullptr;
    Value result;
    if (envelope.get("at") != nullptr) {
      return invalid(error_, envelope.child("at"), "unknown key");
    }
    if (!envelope.req_object("input", &input) ||
        !handler(*input, &result, error_)) {
      return false;
    }
    *response = result_response(type, std::move(result));
    return true;
  }

  // Queries accept an `at` (validated, not used).
  bool run(const ObjectReader& envelope, const std::string& type,
           QueryHandler handler, Value* response) {
    const Value* input = nullptr;
    std::optional<At> at;
    Value result;
    if (!decode_at(envelope.get("at"), AtRule::kOptional,
                   envelope.child("at"), &at, error_) ||
        !envelope.req_object("input", &input) ||
        !handler(*state_, *input, envelope.child("input"), &result, error_)) {
      return false;
    }
    *response = result_response(type, std::move(result));
    return true;
  }

  bool run(const ObjectReader& envelope, const std::string& type,
           const CommandSpec& spec, Value* response) {
    std::vector<Pending> pending(1);
    if (!decode_command(envelope, spec, &pending[0], error_)) {
      return false;
    }
    return commands(type, &pending, response);
  }

  bool batch(const ObjectReader& envelope, Value* response) {
    const Value* messages = nullptr;
    if (envelope.get("at") != nullptr || envelope.get("input") != nullptr) {
      return invalid(error_,
                     envelope.child(envelope.get("at") ? "at" : "input"),
                     "unknown key");
    }
    if (!envelope.req_array("messages", &messages)) {
      return false;
    }
    std::vector<Pending> pending(messages->items().size());
    for (size_t i = 0; i < pending.size(); ++i) {
      const std::string path = "$.messages[" + std::to_string(i) + "]";
      if (!decode_batched(modules_, messages->items()[i], path, &pending[i],
                          error_)) {
        return false;
      }
    }
    return commands("batch", &pending, response);
  }

  // One simulated admission pass over every command, so a rejected command
  // leaves the engine untouched; then apply in order; then commit the
  // lifecycle the simulation reached.
  bool commands(const std::string& type, std::vector<Pending>* pending,
                Value* response) {
    Admission simulated{state_->lifecycle, state_->config.host.has_value()};
    for (Pending& p : *pending) {
      if (simulated.lifecycle == LifecycleState::kDisposed) {
        return invalid(error_, p.path + ".type",
                       "the engine is disposed (engine.dispose)");
      }
      p.lifecycle = simulated.lifecycle;
      p.dropped = p.policy == SessionPolicy::kEventProducing &&
                  !has_live_session(simulated.lifecycle);
      if (!p.dropped && !p.command->admit(&simulated, p.path, error_)) {
        return false;
      }
      if (const std::optional<LifecycleSignal> signal = p.command->signal()) {
        simulated.lifecycle = transition(simulated.lifecycle, *signal);
      }
      p.lifecycle_after = simulated.lifecycle;
    }
    Output out;
    for (Pending& p : *pending) {
      if (p.dropped) continue;
      state_->lifecycle = p.lifecycle;
      state_->applying = AppliedMessage{&modules_, p.at};
      p.command->apply(modules_, state_, &out);
      state_->lifecycle = p.lifecycle_after;
      if (p.at) modules_.run_after_command(*p.at, state_, &out);
    }
    state_->applying = AppliedMessage();
    state_->lifecycle = simulated.lifecycle;
    *response = command_response(type, out);
    return true;
  }

  const ModuleRegistry& modules_;
  EngineState* state_;
  Error* error_;
};

}  // namespace

bool Engine::handle(const Value& message, Value* response, Error* error) {
  return Dispatch(modules_, &state_, error).message(message, response);
}

}  // namespace engine
}  // namespace tugboat
