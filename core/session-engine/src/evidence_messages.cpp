// Adapter and host evidence: `event.record`, `locale.set`, and
// `identity.set` (docs/stateful-engine.md sections 4.3 and 7.2).
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

// Event types the engine mints itself. An adapter cannot record them, so the
// session timeline cannot be forged. Later phases extend the list with the
// types they mint (interaction, route_change, …).
const char* const kEngineEventTypes[] = {
    "session_start",    "session_end",       "app_backgrounded",
    "app_foregrounded", "app_inactive",      "app_detached",
    "locale_changed",
};

bool engine_owned(const std::string& type) {
  for (const char* owned : kEngineEventTypes) {
    if (type == owned) {
      return true;
    }
  }
  return false;
}

// Dart's `jsonEncode` throws on NaN and infinities; reject them on input
// (`1e400`) so applying a command cannot fail later.
bool check_finite(const Value& value, const std::string& path, Error* error) {
  if (value.is_double() && !std::isfinite(value.as_double())) {
    return invalid(error, path, "non-finite number cannot be encoded");
  }
  size_t index = 0;
  for (const Value& item : value.items()) {
    if (!check_finite(item, path + "[" + std::to_string(index++) + "]",
                      error)) {
      return false;
    }
  }
  for (const Member& member : value.members()) {
    if (!check_finite(member.value, path + "." + member.key, error)) {
      return false;
    }
  }
  return true;
}

// ---------------------------------------------------------- event.record

// `{eventType, stream, data?, targetAnchor?, atMonoUs?, attachActionContext}`
class RecordEvent final : public Command {
 public:
  RecordEvent(Event event, int64_t fact_mono_us, bool attach_action_context)
      : event_(std::move(event)),
        fact_mono_us_(fact_mono_us),
        attach_action_context_(attach_action_context) {}

  bool admit(Admission* admission, const std::string& path,
             Error* error) const override {
    return reject_after_end(*admission, path, error);
  }

  void apply(const Transition& transition, EngineState* state,
             Output* out) override {
    if (!has_live_session(transition.from)) {
      // Before the first session there is nothing to record into; Dart's
      // evidence recorder drops it without minting an id.
      return;
    }
    event_.id = state->ids.next("event");
    event_.at_ms = state->session->at_ms(fact_mono_us_);
    record_event(state, std::move(event_), attach_action_context_, out);
  }

 private:
  Event event_;
  int64_t fact_mono_us_;
  bool attach_action_context_;
};

bool decode_record_fields(const ObjectReader& r, Event* event, Error* error) {
  std::string stream;
  const Value* data = nullptr;
  const Value* anchor = nullptr;
  if (!r.req_string("eventType", &event->type) ||
      !r.req_string("stream", &stream) || !r.opt_object("data", &data) ||
      !r.opt_object("targetAnchor", &anchor) ||
      !decode_anchor(anchor, r.child("targetAnchor"), &event->anchor, error)) {
    return false;
  }
  if (event->type.empty()) {
    return r.reject("eventType", "must not be empty");
  }
  if (engine_owned(event->type)) {
    return r.reject("eventType", "the engine records this type itself");
  }
  const std::optional<EventStream> parsed = parse_stream(stream, true);
  if (!parsed) {
    return r.reject("stream",
                    "expected semantic, evidence, diagnostic, or "
                    "legacy_projection");
  }
  event->stream = *parsed;
  if (data != nullptr) {
    if (!check_finite(*data, r.child("data"), error)) {
      return false;
    }
    event->data = *data;
  }
  return true;
}

std::unique_ptr<Command> decode_record(const CommandInput& in, Error* error) {
  const ObjectReader r(in.input, in.path, error);
  Event event;
  std::optional<int64_t> fact_mono_us;
  std::optional<bool> attach;
  if (!r.check_keys({"eventType", "stream", "data", "targetAnchor",
                     "atMonoUs", "attachActionContext"}) ||
      !decode_record_fields(r, &event, error) ||
      !decode_mono_us(r, "atMonoUs", &fact_mono_us) ||
      !r.opt_bool("attachActionContext", &attach)) {
    return nullptr;
  }
  if (!attach) {
    r.reject("attachActionContext", "required");
    return nullptr;
  }
  return std::make_unique<RecordEvent>(
      std::move(event), fact_mono_us.value_or(in.at->mono_us), *attach);
}

// ------------------------------------------------------------ locale.set

// Records the active app locale (Dart `recordLocale`): dedupes, updates the
// current locale, and emits `locale_changed` while a session is live. After
// `session_end` it only updates the locale for the next session (C9).
class SetLocale final : public Command {
 public:
  SetLocale(LocaleInfo locale, At at) : locale_(std::move(locale)), at_(at) {}

  bool admit(Admission*, const std::string&, Error*) const override {
    return true;
  }

  void apply(const Transition& transition, EngineState* state,
             Output* out) override {
    if (state->locale == locale_) {
      return;
    }
    const std::optional<LocaleInfo> previous = state->locale;
    state->locale = locale_;
    if (!has_live_session(transition.from)) {
      return;
    }
    state->session->set_locale(locale_);
    Event event = make_event(state, "locale_changed", at_.mono_us);
    event.stream = EventStream::kEvidence;
    event.locale = locale_;
    if (previous) {
      event.data.set("previousLocale", locale_json(*previous));
    }
    event.data.set("locale", locale_json(locale_));
    record_event(state, std::move(event), true, out);
  }

 private:
  LocaleInfo locale_;
  At at_;
};

std::unique_ptr<Command> decode_locale_set(const CommandInput& in,
                                           Error* error) {
  const ObjectReader r(in.input, in.path, error);
  std::optional<LocaleInfo> locale;
  if (!r.check_keys({"locale"}) ||
      !decode_locale(r.get("locale"), r.child("locale"), &locale, error)) {
    return nullptr;
  }
  if (!locale) {
    r.reject("locale", "required");
    return nullptr;
  }
  return std::make_unique<SetLocale>(std::move(*locale), *in.at);
}

// ---------------------------------------------------------- identity.set

// Sets the runtime user id (null clears it). Events recorded afterwards
// carry it; earlier records keep theirs (stamped at record time).
class SetIdentity final : public Command {
 public:
  explicit SetIdentity(OptString user_id) : user_id_(std::move(user_id)) {}

  bool admit(Admission*, const std::string&, Error*) const override {
    return true;
  }

  void apply(const Transition&, EngineState* state, Output*) override {
    state->identity.user_id = user_id_;
    state->identity.set_explicitly = true;
  }

 private:
  OptString user_id_;
};

std::unique_ptr<Command> decode_identity(const CommandInput& in,
                                         Error* error) {
  const ObjectReader r(in.input, in.path, error);
  OptString user_id;
  if (!r.check_keys({"userId"}) || !r.opt_string("userId", &user_id)) {
    return nullptr;
  }
  return std::make_unique<SetIdentity>(std::move(user_id));
}

}  // namespace

void register_evidence_messages(MessageRegistry* registry) {
  registry->add_command("event.record", AtRule::kMono, decode_record);
  registry->add_command("locale.set", AtRule::kMono, decode_locale_set);
  registry->add_command("identity.set", AtRule::kMonoAndWall,
                        decode_identity);
}

}  // namespace engine
}  // namespace tugboat
