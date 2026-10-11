// Event enrichment and append (Dart `_addEvent`, docs/stateful-engine.md
// section 4.4). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_RECORDER_H
#define TUGBOAT_SESSION_ENGINE_RECORDER_H

#include <optional>

#include "engine_state.h"
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
// The exploration action window (`actionId`) is not part of any phase yet,
// so the event's own `actionId` passes through unchanged.
Event enrich(Event event, const Session& session,
             const std::optional<LocaleInfo>& current_locale,
             bool attach_action_context);

// Enriches `event`, appends it to the live session, emits its event record
// (stamped with the runtime user id), then trims. Append order is record
// order. The caller guarantees a session exists.
void record_event(EngineState* state, Event event, bool attach_action_context,
                  Output* out);

// Mints `event-N` and builds an engine-produced event at `mono_us`.
Event make_event(EngineState* state, const char* type, int64_t mono_us);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_RECORDER_H
