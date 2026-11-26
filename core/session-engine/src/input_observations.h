// Focus and system-input evidence (Dart `recordFocusChange`,
// `recordSystemInput`, and `FocusChangeCapture`): each `focus_changed` or
// `system_input` event waits for one visual observation and publishes
// exactly once, with the observed frame, or without one when the session
// ends, is replaced, or goes to the background first.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INPUT_OBSERVATIONS_H
#define TUGBOAT_SESSION_ENGINE_INPUT_OBSERVATIONS_H

#include <string>

#include "capture_types.h"
#include "interaction_facts.h"
#include "models.h"
#include "ordered_map.h"
#include "route_work.h"
#include "turn.h"

namespace tugboat {
namespace engine {

struct PendingObservation {
  Event event;
  std::string session_id;
};

struct InputObservations {
  // Waiting events by event id, in input order.
  OrderedMap<std::string, PendingObservation> pending;
  // The kind of node holding primary focus. Tracked across sessions, like
  // the adapter's focus listener.
  FocusKind focus = FocusKind::kNone;
};

// A focus change. Only transitions into, out of, or between text inputs are
// evidence; churn between other nodes is ignored. `session` may be null (no
// live session): the kind is still tracked.
void record_focus(EngineState* state, Session* session, const At& at,
                  FocusKind kind, Output* out);

void record_system_input(Turn& turn, SystemInput input);

// The observation capture of event `event_id` resolved.
void finish_observation(Turn& turn, const std::string& event_id,
                        const CaptureResolution& resolution);

// The route barrier the observation waits on is done.
void observation_route_barrier_done(Turn& turn, const std::string& event_id,
                                    const RouteWork& barrier);

// Teardown: publishes every waiting event without a frame, in input order.
void flush_observations(EngineState* state, Output* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INPUT_OBSERVATIONS_H
