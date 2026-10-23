#include "capture_scheduler.h"

#include <algorithm>
#include <utility>

namespace tugboat {
namespace engine {

namespace {

// Dart `_ScheduledCapture._triggerPriority`.
int trigger_priority(FrameTrigger trigger) {
  switch (trigger) {
    case FrameTrigger::kManual: return 7;
    case FrameTrigger::kInteraction: return 6;
    case FrameTrigger::kRoute: return 5;
    case FrameTrigger::kLifecycle: return 4;
    case FrameTrigger::kTap: return 3;
    case FrameTrigger::kScroll: return 2;
    case FrameTrigger::kInitial: return 1;
  }
  return 1;
}

bool erase_waiter(std::vector<CaptureWaiter>* waiters,
                  const std::string& request_id,
                  std::optional<CaptureWaiter>* removed) {
  const auto it = std::find_if(
      waiters->begin(), waiters->end(),
      [&](const CaptureWaiter& w) { return w.request_id == request_id; });
  if (it == waiters->end()) return false;
  *removed = std::move(*it);
  waiters->erase(it);
  return true;
}

}  // namespace

bool ScheduledCapture::can_absorb(const ScheduledCapture& other) const {
  return trigger != FrameTrigger::kInteraction &&
         other.trigger != FrameTrigger::kInteraction &&
         context.compatible_with(other.context);
}

void ScheduledCapture::absorb(ScheduledCapture other) {
  if (trigger_priority(other.trigger) >= trigger_priority(trigger)) {
    trigger = other.trigger;
  }
  force = force || other.force;
  if (other.freshness == CaptureFreshness::kFreshPaint) {
    freshness = CaptureFreshness::kFreshPaint;
  }
  drop_when_busy = drop_when_busy && other.drop_when_busy;
  not_before_mono_us = std::max(not_before_mono_us, other.not_before_mono_us);
  enqueued_mono_us = std::min(enqueued_mono_us, other.enqueued_mono_us);
  for (CaptureWaiter& waiter : waiters) waiter.coalesced = true;
  for (CaptureWaiter& waiter : other.waiters) {
    waiter.coalesced = true;
    waiters.push_back(std::move(waiter));
  }
}

void CaptureScheduler::enqueue(ScheduledCapture capture) {
  if (!queue_.empty() && queue_.back().can_absorb(capture)) {
    queue_.back().absorb(std::move(capture));
    return;
  }
  queue_.push_back(std::move(capture));
}

ScheduledCapture CaptureScheduler::take_head() {
  ScheduledCapture head = std::move(queue_.front());
  queue_.pop_front();
  return head;
}

std::optional<InFlightCapture> CaptureScheduler::finish() {
  std::optional<InFlightCapture> done = std::move(in_flight_);
  in_flight_.reset();
  return done;
}

std::optional<CaptureWaiter> CaptureScheduler::remove_waiter(
    const std::string& request_id) {
  std::optional<CaptureWaiter> removed;
  for (auto it = queue_.begin(); it != queue_.end(); ++it) {
    if (!erase_waiter(&it->waiters, request_id, &removed)) continue;
    if (it->waiters.empty()) queue_.erase(it);
    return removed;
  }
  if (in_flight_) {
    erase_waiter(&in_flight_->capture.waiters, request_id, &removed);
  }
  return removed;
}

std::vector<CaptureWaiter> CaptureScheduler::take_all_waiters(
    bool abandon_in_flight) {
  std::vector<CaptureWaiter> waiters;
  if (in_flight_) {
    waiters = std::move(in_flight_->capture.waiters);
    in_flight_->capture.waiters.clear();
    if (abandon_in_flight) in_flight_.reset();
  }
  for (ScheduledCapture& scheduled : queue_) {
    for (CaptureWaiter& waiter : scheduled.waiters) {
      waiters.push_back(std::move(waiter));
    }
  }
  queue_.clear();
  return waiters;
}

std::string CaptureScheduler::next_host_request_id() {
  return "capture-" + std::to_string(host_requests_++);
}

namespace {

void stamp_initial_route_onto(RequestContext* context,
                              const VisibleRoute& visible) {
  if (context->trigger != FrameTrigger::kInitial) return;
  context->route = visible.route;
  context->navigator_id = visible.navigator_id;
  context->route_instance_id = visible.route_instance_id;
}

}  // namespace

void CaptureScheduler::restamp_initial_route(const VisibleRoute& visible) {
  for (ScheduledCapture& scheduled : queue_) {
    stamp_initial_route_onto(&scheduled.context, visible);
    for (CaptureWaiter& waiter : scheduled.waiters) {
      stamp_initial_route_onto(&waiter.context, visible);
    }
  }
  if (in_flight_.has_value()) {
    stamp_initial_route_onto(&in_flight_->capture.context, visible);
    for (CaptureWaiter& waiter : in_flight_->capture.waiters) {
      stamp_initial_route_onto(&waiter.context, visible);
    }
  }
}

}  // namespace engine
}  // namespace tugboat
