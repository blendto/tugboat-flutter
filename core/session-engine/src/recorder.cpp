#include "recorder.h"

#include <utility>

namespace tugboat {
namespace engine {

namespace {

// Dart `a ?? b`.
OptString first_defined(const OptString& a, const OptString& b) {
  return a ? a : b;
}

}  // namespace

Event enrich(Event event, const Session& session,
             const std::optional<LocaleInfo>& current_locale,
             bool attach_action_context) {
  if (!event.locale && current_locale) {
    event.locale = current_locale;
  }
  const SessionHeader& header = session.header();
  if (attach_action_context) {
    event.capture_session_id = header.id;
    event.activation_request_id =
        first_defined(header.activation_request_id,
                      event.activation_request_id);
    event.exploration_run_id =
        first_defined(event.exploration_run_id, header.exploration_run_id);
  } else {
    event.capture_session_id =
        first_defined(event.capture_session_id, header.id);
    event.activation_request_id = first_defined(
        event.activation_request_id, header.activation_request_id);
    event.exploration_run_id =
        first_defined(event.exploration_run_id, header.exploration_run_id);
  }
  return event;
}

void record_event(EngineState* state, Session& session, Event event,
                  bool attach_action_context, Output* out) {
  Event enriched = enrich(std::move(event), session, state->locale,
                          attach_action_context);
  out->records.push_back(EventRecord{enriched, state->identity.user_id});
  session.append(std::move(enriched), state->config.limits.max_events);
}

Event make_event(EngineState* state, const Session& session,
                 const char* type, int64_t mono_us) {
  Event event;
  event.id = state->ids.next("event");
  event.at_ms = session.at_ms(mono_us);
  event.type = type;
  return event;
}

}  // namespace engine
}  // namespace tugboat
