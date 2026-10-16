// Waiting on a route barrier (Dart `_awaitRouteCaptureBarrier`): a waiter
// resumes, as deferred work, once the barrier is done. A barrier cancelled
// by a successor on its navigator passes the waiter on to that successor,
// unless the waiter expects a cause the successor does not carry. Any other
// outcome (captured, failed, timed out, or cancelled without a successor)
// ends the wait on that barrier. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ROUTE_BARRIER_H
#define TUGBOAT_SESSION_ENGINE_ROUTE_BARRIER_H

#include "route_work.h"

namespace tugboat {
namespace engine {

struct EngineState;
struct BarrierResume;

// Waits for `work`'s barrier on behalf of `waiter`.
void await_route_barrier(EngineState* state, const RouteWorkPtr& work,
                         BarrierWaiter waiter);

// `work` is done: every waiter resumes (deferred).
void release_barrier_waiters(EngineState* state, const RouteWorkPtr& work);

// A resumed waiter: follows a cancelled barrier to its successor (waiting
// again, and returning nullptr) or returns the barrier the wait ended on.
RouteWorkPtr settle_barrier_resume(EngineState* state,
                                   const BarrierResume& resume);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_ROUTE_BARRIER_H
