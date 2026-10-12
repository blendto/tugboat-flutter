// The route-capture work state machine (Dart `route()`, `_RouteCaptureWork`,
// `_finalizeRouteCapture`, `_timeoutRouteCapture`, design section 8.1):
//
//   1. a removal that reveals nothing new is ignored (route_change.h);
//   2. the cause is claimed before the route epoch advances;
//   3. prior work on the same navigator is cancelled, every waiting capture
//      with it, and the capture generation advances;
//   4. the new barrier gets `++routeEpoch` and the prior links it as
//      `supersededBy`;
//   5. the claimed tap is woken only once the barrier is registered;
//   6. after `transitionMs + settleDelay` it requests a forced `route`
//      capture through the publication queue and records `route_change`;
//   7. `routeBarrierTimeoutMs` after that deadline it records
//      `route_change` with `captureOutcome: timed_out` instead.
//
// Timers: `navigation.deadline.<epoch>` (step 6) and
// `navigation.timeout.<epoch>` (step 7). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ROUTE_CAPTURE_H
#define TUGBOAT_SESSION_ENGINE_ROUTE_CAPTURE_H

#include <string>

#include "capture_types.h"
#include "clock.h"
#include "output.h"
#include "route_change.h"
#include "route_work.h"
#include "turn.h"

namespace tugboat {
namespace engine {

struct EngineState;

constexpr char kRouteDeadlinePrefix[] = "navigation.deadline.";
constexpr char kRouteTimeoutPrefix[] = "navigation.timeout.";

// Steps 3 to 6 for a resolved change: the visible route changes, prior work
// on the navigator is superseded, and the new work starts.
void start_route_capture(Turn& turn, VisibleRouteChange change);

// The deadline of the work with `epoch` passed: its navigator's transition
// suppression ends and the work joins the publication queue.
void route_deadline_reached(Turn& turn, const std::string& epoch);

// The work with `epoch` timed out (step 7).
void route_barrier_timed_out(Turn& turn, const std::string& epoch);

// The publication queue reached the work: it requests its route capture.
// Returns whether it now holds the queue (false when it is no longer
// active).
bool begin_route_finalize(Turn& turn, const RouteWorkPtr& work);

// The route capture of the finalizing work with `epoch` resolved.
void finish_route_capture(Turn& turn, const std::string& epoch,
                          const CaptureResolution& resolution);

// Teardown (Dart `_cancelActiveRouteCapture`): cancels every active work
// and forgets causal links, suppression, and queued publications.
void cancel_route_captures(EngineState* state, const At& at, Output* out,
                           CancelReason reason);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_ROUTE_CAPTURE_H
