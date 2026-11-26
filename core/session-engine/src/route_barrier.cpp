#include "route_barrier.h"

#include <utility>

#include "coordination.h"
#include "engine_state.h"

namespace tugboat {
namespace engine {

namespace {

// Dart: only explicit cancellation by a successor can transfer a waiter,
// and an expected cause must be the successor's cause too.
RouteWorkPtr successor_for(const RouteWork& work,
                           const BarrierWaiter& waiter) {
  if (work.result->outcome != RouteOutcome::kCancelled) return nullptr;
  const RouteWorkPtr& successor = work.superseded_by;
  if (successor == nullptr || successor.get() == &work) return nullptr;
  if (waiter.expected_cause) {
    const std::string* cause = successor->change.cause_event_id();
    if (cause == nullptr || *cause != *waiter.expected_cause) return nullptr;
  }
  return successor;
}

}  // namespace

void await_route_barrier(EngineState* state, const RouteWorkPtr& work,
                         BarrierWaiter waiter) {
  if (work->done()) {
    defer(state, BarrierResume{std::move(waiter), work});
    return;
  }
  work->waiters.push_back(std::move(waiter));
}

void release_barrier_waiters(EngineState* state, const RouteWorkPtr& work) {
  std::vector<BarrierWaiter> waiters = std::move(work->waiters);
  work->waiters.clear();
  for (BarrierWaiter& waiter : waiters) {
    defer(state, BarrierResume{std::move(waiter), work});
  }
}

RouteWorkPtr settle_barrier_resume(EngineState* state,
                                   const BarrierResume& resume) {
  const RouteWorkPtr successor = successor_for(*resume.work, resume.waiter);
  if (successor == nullptr) return resume.work;
  await_route_barrier(state, successor, resume.waiter);
  return nullptr;
}

}  // namespace engine
}  // namespace tugboat
