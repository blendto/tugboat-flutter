// Host identity (docs/stateful-engine.md sections 4.1, 7.1, and 7.2):
// `identity.set {userId}` and `traits.set {traits}`. The runtime user id is
// stamped on event records when they are recorded; collector delivery posts
// identity changes to `/v1/sessions` after a debounce.
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "delivery.h"
#include "modules.h"

namespace tugboat {
namespace engine {

namespace {

// Shallow map equality like Dart `mapEquals` on `Map<String, dynamic>`:
// scalars compare by value (`1 == 1.0`), nested maps and lists by identity,
// which two decoded bags never share.
bool same_value(const Value& a, const Value& b) {
  if (a.is_number() && b.is_number()) {
    return a.is_int() && b.is_int() ? a.as_int() == b.as_int()
                                    : a.to_double() == b.to_double();
  }
  if (a.kind() != b.kind()) {
    return false;
  }
  switch (a.kind()) {
    case Value::Kind::kNull: return true;
    case Value::Kind::kBool: return a.as_bool() == b.as_bool();
    case Value::Kind::kString: return a.as_string() == b.as_string();
    default: return false;
  }
}

bool map_equals(const std::optional<Value>& current, const Value& next) {
  if (!current || current->members().size() != next.members().size()) {
    return false;
  }
  for (const Member& member : current->members()) {
    const Value* other = next.find(member.key);
    if (other == nullptr || !same_value(member.value, *other)) {
      return false;
    }
  }
  return true;
}

// Sets the runtime user id (null clears it). Events recorded afterwards
// carry it; earlier records keep theirs (stamped at record time).
class SetIdentity final : public Command {
 public:
  SetIdentity(OptString user_id, At at)
      : user_id_(std::move(user_id)), at_(at) {}

  void apply(const ModuleRegistry&, EngineState* state,
             Output* out) override {
    const bool changed = state->identity.user_id != user_id_;
    state->identity.user_id = user_id_;
    state->identity.set_explicitly = true;
    if (changed) {
      delivery_user_changed(at_, state, out);
    }
  }

 private:
  OptString user_id_;
  At at_;
};

std::unique_ptr<Command> decode_identity(const CommandInput& in,
                                         Error* error) {
  const ObjectReader r(in.input, in.path, error);
  OptString user_id;
  if (!r.check_keys({"userId"}) || !r.opt_string("userId", &user_id)) {
    return nullptr;
  }
  return std::make_unique<SetIdentity>(std::move(user_id), *in.at);
}

// Replaces the host's traits bag (Dart `setTraits`). It survives sessions;
// lifecycle posts carry it in full (or the collector's `traitsId` while no
// bag is set). A bag equal to the current one is no change.
class SetTraits final : public Command {
 public:
  SetTraits(Value traits, At at) : traits_(std::move(traits)), at_(at) {}

  void apply(const ModuleRegistry&, EngineState* state,
             Output* out) override {
    if (map_equals(state->identity.traits, traits_)) {
      return;
    }
    state->identity.traits = std::move(traits_);
    delivery_traits_changed(at_, state, out);
  }

 private:
  Value traits_;
  At at_;
};

std::unique_ptr<Command> decode_traits(const CommandInput& in, Error* error) {
  const ObjectReader r(in.input, in.path, error);
  const Value* traits = nullptr;
  if (!r.check_keys({"traits"}) || !r.req_object("traits", &traits)) {
    return nullptr;
  }
  return std::make_unique<SetTraits>(*traits, *in.at);
}

}  // namespace

void register_identity_module(ModuleRegistry* registry) {
  registry->add_command("identity.set",
                        {AtRule::kMonoAndWall, SessionPolicy::kAny,
                         decode_identity});
  registry->add_command("traits.set",
                        {AtRule::kMonoAndWall, SessionPolicy::kAny,
                         decode_traits});
}

}  // namespace engine
}  // namespace tugboat
