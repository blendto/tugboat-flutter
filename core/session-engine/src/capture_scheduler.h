// The capture scheduler's queue (Dart `_ScheduledCapture`, `_CaptureWaiter`,
// `_queueScheduledCapture`, and the one `_activeScheduledCapture`): logical
// requests wait in a FIFO of scheduled captures; a request joins the tail
// when both are absorbable; one capture is in flight at a time. This file
// holds the data and its invariants; capture_seam.cpp decides when the head
// runs and what an execution resolves to (capture_execution.h).
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_SCHEDULER_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_SCHEDULER_H

#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <vector>

#include "capture_types.h"
#include "frame_store.h"
#include "models.h"

namespace tugboat {
namespace engine {

// Dart `_CaptureFreshness`: whether a capture must observe a fresh paint.
enum class CaptureFreshness { kReusable, kFreshPaint };

// One logical request (`capture_request-N`) and who waits for it.
struct CaptureWaiter {
  std::string request_id;
  // The context when it was requested, with its own trigger.
  RequestContext context;
  CaptureOwner owner;
  OptString related_event_id;
  // Set once it shares an execution with another request.
  bool coalesced = false;
};

// One scheduled physical capture and the requests it serves.
struct ScheduledCapture {
  FrameTrigger trigger = FrameTrigger::kManual;
  bool force = false;
  CaptureFreshness freshness = CaptureFreshness::kReusable;
  // Every request it serves is low priority (dropped instead of queued when
  // the scheduler was busy). Informative for the host.
  bool drop_when_busy = false;
  int64_t not_before_mono_us = 0;
  int64_t enqueued_mono_us = 0;
  // The first request's context.
  RequestContext context;
  std::vector<CaptureWaiter> waiters;

  // Dart `canAbsorb`: interaction captures never share an execution, and
  // others only with a compatible context.
  bool can_absorb(const ScheduledCapture& other) const;
  // Dart `absorb`: the higher-priority trigger (manual > interaction > route
  // > lifecycle > tap > scroll > initial; a tie takes the newcomer), force
  // and freshness if either needs them, low priority only if both are, the
  // later not-before, the earlier enqueue time; every waiter becomes
  // coalesced.
  void absorb(ScheduledCapture other);
};

// The capture the host is performing (`capture.request` issued, no
// `capture.result` yet).
struct InFlightCapture {
  std::string host_request_id;  // `capture-N`
  ScheduledCapture capture;
  int64_t generation = 0;       // the capture generation when issued
  int64_t queue_wait_us = 0;
  // What the request told the host: forced captures never report
  // `paintUnchanged` and never coalesce.
  bool forced = false;
  std::optional<DHashBaseline> baseline;
};

class CaptureScheduler {
 public:
  // Dart `_queueScheduledCapture`.
  void enqueue(ScheduledCapture capture);
  // Dart `_captureQueueIsBusy`.
  bool busy() const { return in_flight_.has_value() || !queue_.empty(); }
  const ScheduledCapture* head() const {
    return queue_.empty() ? nullptr : &queue_.front();
  }
  ScheduledCapture take_head();

  InFlightCapture* in_flight() { return in_flight_ ? &*in_flight_ : nullptr; }
  void start(InFlightCapture capture) { in_flight_ = std::move(capture); }
  // Ends the in-flight capture and returns it (nothing when idle).
  std::optional<InFlightCapture> finish();

  // Dart `_cancelCaptureWaiter`: removes one request wherever it waits. An
  // emptied scheduled capture leaves the queue; an in-flight one keeps
  // running for no one.
  std::optional<CaptureWaiter> remove_waiter(const std::string& request_id);
  // Dart `_cancelScheduledCaptureWaiters`: every request, in-flight ones
  // first, then the queue in order. The queue empties; the in-flight
  // capture keeps running unless `abandon_in_flight`.
  std::vector<CaptureWaiter> take_all_waiters(bool abandon_in_flight);

  // Dart `_captureGeneration`: advancing it makes every capture in flight
  // stale.
  int64_t generation() const { return generation_; }
  void advance_generation() { ++generation_; }
  // `capture-N`: one per physical attempt, never reused.
  std::string next_host_request_id();

 private:
  std::deque<ScheduledCapture> queue_;
  std::optional<InFlightCapture> in_flight_;
  int64_t generation_ = 0;
  int64_t host_requests_ = 0;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_SCHEDULER_H
