// Event enrichment and append (Dart `_addEvent`, docs/stateful-engine.md
// section 4.4). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_RECORDER_H
#define TUGBOAT_SESSION_ENGINE_RECORDER_H

#include <cstdint>
#include <optional>

#include "clock.h"
#include "engine_state.h"
#include "json.h"
#include "models.h"
#include "output.h"
#include "session.h"

namespace tugboat {
namespace engine {

// Stamps session context onto `event` exactly as `_addEvent` does:
// - the current locale when the event carries none;
// - with `attach_action_context`, the session's capture, activation, and
//   exploration ids (`withExplorationContext`);
// - without it, those ids only where the event has none, so host evidence
//   keeps its own context.
// The exploration action window (`actionId`) is deferred beyond this
// milestone, so the event's own `actionId` passes through unchanged.
Event enrich(Event event, const Session& session,
             const std::optional<LocaleInfo>& current_locale,
             bool attach_action_context);

// Enriches `event`, appends it to `session` (the live session), emits its
// event record stamped with the runtime user id, then trims. Append order
// is record order. Event record observers (module_registry.h) then see the
// record.
void record_event(EngineState* state, Session& session, Event event,
                  bool attach_action_context, Output* out);

// Mints `event-N` and builds an engine-produced event at `mono_us`.
Event make_event(EngineState* state, const Session& session,
                 const char* type, int64_t mono_us);

// An engine-produced `capture_diagnostic`: `data` on the diagnostic stream
// under a minted `event-N`, unless `id` and `stream` say otherwise
// (collector delivery gaps keep Dart's `collector-…` ids and stream).
struct Diagnostic {
  Value data = Value::object();
  OptString after_frame;
  OptString id;
  EventStream stream = EventStream::kDiagnostic;
};

// The `capture_diagnostic` event of `diagnostic` in `session` at `mono_us`.
Event diagnostic_event(EngineState* state, const Session& session,
                       int64_t mono_us, Diagnostic diagnostic);

// Records `diagnostic` in the live session (with the session's action
// context). Without a live session nothing is recorded or minted, and it
// returns false.
bool record_diagnostic(EngineState* state, const At& at, Output* out,
                       Diagnostic diagnostic);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_RECORDER_H
