// Adapter and host evidence: `event.record` and `locale.set`
// (docs/stateful-engine.md section 4.3). `identity.set` is in
// identity_module.cpp.
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "modules.h"
#include "recorder.h"

namespace tugboat {
namespace engine {

namespace {

// ---------------------------------------------------------- event.record

// `{eventType, stream, data?, targetAnchor?, atMonoUs?, attachActionContext}`.
// Event-producing: without a live session the dispatcher drops it.
class RecordEvent final : public Command {
 public:
  RecordEvent(Event event, int64_t fact_mono_us, bool attach_action_context)
      : event_(std::move(event)),
        fact_mono_us_(fact_mono_us),
        attach_action_context_(attach_action_context) {}

  void apply(const ModuleRegistry&, EngineState* state,
             Output* out) override {
    Session& session = *state->live_session();
    event_.id = state->ids.next("event");
    event_.at_ms = session.at_ms(fact_mono_us_);
    record_event(state, session, std::move(event_), attach_action_context_,
                 out);
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
  // Types the engine records itself cannot be forged by an adapter.
  if (module_registry().is_engine_event_type(event->type)) {
    return r.reject("eventType", "the engine records this type itself");
  }
  const std::optional<EventStream> parsed = parse_stream(stream);
  if (!parsed) {
    return r.reject("stream", "expected semantic, evidence, or diagnostic");
  }
  event->stream = *parsed;
  if (data != nullptr) {
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
// current locale, and emits `locale_changed` while a session is live.
// Without a live session it only updates the locale for the next one.
class SetLocale final : public Command {
 public:
  SetLocale(LocaleInfo locale, At at) : locale_(std::move(locale)), at_(at) {}

  void apply(const ModuleRegistry&, EngineState* state,
             Output* out) override {
    if (state->locale == locale_) {
      return;
    }
    const std::optional<LocaleInfo> previous = state->locale;
    state->locale = locale_;
    Session* session = state->live_session();
    if (session == nullptr) {
      return;
    }
    session->set_locale(locale_);
    Event event = make_event(state, *session, "locale_changed", at_.mono_us);
    event.stream = EventStream::kEvidence;
    event.locale = locale_;
    if (previous) {
      event.data.set("previousLocale", locale_json(*previous));
    }
    event.data.set("locale", locale_json(locale_));
    record_event(state, *session, std::move(event), true, out);
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

}  // namespace

void register_evidence_module(ModuleRegistry* registry) {
  registry->add_command("event.record",
                        {AtRule::kMono, SessionPolicy::kEventProducing,
                         decode_record});
  registry->add_command("locale.set",
                        {AtRule::kMono, SessionPolicy::kAny,
                         decode_locale_set});
  registry->add_engine_event_type("locale_changed");
}

}  // namespace engine
}  // namespace tugboat
