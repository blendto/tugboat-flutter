// What other modules read from navigation (docs/stateful-engine.md section
// 8): the visible route a pointer-down records, the context a capture is
// requested in, transition suppression, and the route captures a waiter
// may join. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_NAVIGATION_VIEW_H
#define TUGBOAT_SESSION_ENGINE_NAVIGATION_VIEW_H

#include <string>

#include "frame_store.h"
#include "interaction_transaction.h"
#include "models.h"
#include "route_work.h"

namespace tugboat {
namespace engine {

struct EngineState;

// The visible route now (an interaction's origin).
RouteStamp current_route_stamp(const EngineState& state);

// Dart `_captureContext(trigger)`: the live session, the visible route and
// its epoch, and the observed capture boundary.
RequestContext current_request_context(const EngineState& state,
                                       FrameTrigger trigger);

// Change C11: whether a capture in `navigator_id`'s context is suppressed
// because that navigator is in a transition.
bool transition_suppresses(const EngineState& state,
                           const OptString& navigator_id);

// Dart `_activeRouteCapture`: the most recently started active route
// capture of any navigator, or nullptr.
RouteWorkPtr latest_route_capture(const EngineState& state);

// Dart `_causalRouteCaptureFor`: the route capture `interaction_id` caused,
// if it is still to be consumed.
RouteWorkPtr causal_route_capture(const EngineState& state,
                                  const std::string& interaction_id);

// Whether the route `interaction_id` caused was replaced by another
// navigation that it did not cause.
bool cause_was_superseded(const EngineState& state,
                          const std::string& interaction_id);

// Dart `_clearCausalRouteState`: the interaction reached a terminal state.
void clear_causal_route_state(EngineState* state,
                              const std::string& interaction_id);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_NAVIGATION_VIEW_H
