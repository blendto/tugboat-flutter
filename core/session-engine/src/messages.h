// Message dispatch: a registry keyed by message `type`. Each module registers
// its own handlers from its own file (`modules.h`), so phases can add
// message types without touching the dispatcher.
//
// Three kinds of message:
// - stateless: the slice 2 operations; respond with `result`.
// - query: reads engine state; responds with `result` (`session.snapshot`).
// - command: changes engine state; responds with `records` and `effects`.
//   Commands go through decode, admit, and apply, so a `batch` can be
//   validated as a whole before any of it is applied.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_MESSAGES_H
#define TUGBOAT_SESSION_ENGINE_MESSAGES_H

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <variant>

#include "clock.h"
#include "engine_state.h"
#include "json.h"
#include "lifecycle.h"
#include "output.h"
#include "reader.h"

namespace tugboat {
namespace engine {

// A decoded command. Decoding never reads engine state; `admit` checks the
// command against the admission state it will see; `apply` cannot fail.
class Command {
 public:
  virtual ~Command() = default;

  // Rejects the command when `*admission` does not allow it, otherwise
  // advances `*admission` to the state after this command. `path` is the
  // message's JSON path (`$` or `$.messages[i]`).
  virtual bool admit(Admission* admission, const std::string& path,
                     Error* error) const = 0;

  // Applies the command. `transition` is the lifecycle change computed by
  // `admit`.
  virtual void apply(const Transition& transition, EngineState* state,
                     Output* out) = 0;
};

// What a command decoder sees: the message `input` object, its JSON path,
// and the decoded `at` (present unless the type's rule is `kNone`).
struct CommandInput {
  const Value& input;
  std::string path;
  std::optional<At> at;
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
  CommandDecoder decode = nullptr;
};

using MessageSpec = std::variant<StatelessHandler, QueryHandler, CommandSpec>;

class MessageRegistry {
 public:
  void add_stateless(const char* type, StatelessHandler handler);
  void add_query(const char* type, QueryHandler handler);
  void add_command(const char* type, AtRule at, CommandDecoder decode);

  // nullptr for an unknown type.
  const MessageSpec* find(std::string_view type) const;

 private:
  void add(const char* type, MessageSpec spec);

  std::map<std::string, MessageSpec, std::less<>> specs_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_MESSAGES_H
