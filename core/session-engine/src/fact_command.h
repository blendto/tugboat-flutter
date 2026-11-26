// A command made of one typed fact: decode the message `input` into the
// fact, then apply it with the fact's time. Modules register their facts
// with `decode_fact<Fact, Decode, Apply>`. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_FACT_COMMAND_H
#define TUGBOAT_SESSION_ENGINE_FACT_COMMAND_H

#include <memory>
#include <string>
#include <utility>

#include "module_registry.h"

namespace tugboat {
namespace engine {

// Applies one decoded fact. Event-producing facts only apply with a live
// session (the dispatcher drops the rest).
template <typename Fact>
using FactHandler = void (*)(const ModuleRegistry& modules, EngineState* state,
                             const Fact& fact, const At& at, Output* out);

template <typename Fact, FactHandler<Fact> Apply>
class FactCommand final : public Command {
 public:
  FactCommand(Fact fact, At at) : fact_(std::move(fact)), at_(at) {}

  void apply(const ModuleRegistry& modules, EngineState* state,
             Output* out) override {
    Apply(modules, state, fact_, at_, out);
  }

 private:
  Fact fact_;
  At at_;
};

template <typename Fact,
          bool (*Decode)(const Value&, const std::string&, Fact*, Error*),
          FactHandler<Fact> Apply>
std::unique_ptr<Command> decode_fact(const CommandInput& in, Error* error) {
  Fact fact{};
  if (!Decode(in.input, in.path, &fact, error)) return nullptr;
  return std::make_unique<FactCommand<Fact, Apply>>(std::move(fact), *in.at);
}

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_FACT_COMMAND_H
