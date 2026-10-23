// The capture seam (design section 8.2): the one interface through which
// the engine asks the host for frames and learns what they were. Behind it
// is the capture scheduler:
//
// - Logical requests (`capture_request-N`) join a FIFO with tail absorption
//   (capture_scheduler.h). One capture is in flight at a time; the engine
//   waits out each request's not-before time itself (timer `capture.due`)
//   so later requests can still be absorbed.
// - An execution resolves by the decision order of capture_execution.h,
//   each waiter by its own compatibility, with one `capture_execution-N`
//   id per execution (one per request for cancellations and rejections),
//   in Dart's id order. With the `captureDiagnostics` capability every
//   resolution is a `capture_diagnostic` event; without it, host contract
//   failures always are, and a secure window once per route instance
//   (capture_diagnostics.h). An accepted frame with `maskCoverage` always
//   records a `capture_masking` diagnostic.
// - Answers reach their owners as deferred work (coordination.h).
// - Frame provenance, the latest frame, and the coalesce baselines are the
//   frame store (frame_store.h); the screenshot budget is capture_budget.h.
//
// Requests and their ids are per engine handle; the host's `capture-N`
// request ids count physical attempts. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_SEAM_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_SEAM_H

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "capture_budget.h"
#include "capture_diagnostics.h"
#include "capture_execution.h"
#include "capture_scheduler.h"
#include "capture_types.h"
#include "clock.h"
#include "frame_store.h"
#include "models.h"
#include "output.h"
#include "turn.h"

namespace tugboat {
namespace engine {

struct EngineState;

// What to ask for (Dart `_requestCaptureCancellable` arguments).
struct CaptureAsk {
  FrameTrigger trigger = FrameTrigger::kManual;
  bool force = false;
  // Low priority: dropped (`capture_pressure_drop`) when the scheduler is
  // busy instead of queued.
  bool drop_when_busy = false;
  // Not before this long after the request.
  int64_t settle_delay_ms = 0;
  OptString related_event_id;
};

// A completed interaction asks for a fresh `interaction` frame now (Dart:
// `trigger: interaction, force: true, settleDelay: zero`).
CaptureAsk interaction_capture(const std::string& related_event_id);

// The capture boundary as last observed: from a `surface` fact, or from
// the `boundaryRect` of an accepted frame.
struct BoundaryObservation {
  std::optional<BoundaryRect> rect;
  int64_t generation = 0;
};

// The timer that runs the queue head once its not-before time has come.
constexpr char kCaptureDueTimerId[] = "capture.due";
// Change C18: `capture.answer.<capture-N>`, the host's answer deadline.
constexpr char kCaptureAnswerTimerPrefix[] = "capture.answer.";

class CaptureSeam {
 public:
  // Session start: forgets frames, baselines, the observed boundary, and
  // the secure-window log. The queue is empty by then (teardown
  // invalidated it); the capture generation, the budget, and the host
  // request counter carry on.
  void reset();
  // Teardown: records the secure-window repeats counted since the last
  // report (SecureWindowLog).
  void report_secure_windows(EngineState* state, const At& at, Output* out);

  // Mints `capture_request-N` for `owner` with the current context and
  // schedules it (or resolves it at once when suppressed or dropped).
  // Returns the request id.
  std::string request(Turn& turn, const CaptureOwner& owner,
                      const CaptureAsk& ask);
  // Dart `_cancelCaptureWaiter`: resolves one waiting request as cancelled.
  void cancel(EngineState* state, const At& at, Output* out,
              const std::string& request_id, CancelReason reason);
  // Dart `_cancelScheduledCaptureWaiters`: resolves every waiting request
  // as cancelled. The capture in flight keeps running for no one.
  void cancel_all(EngineState* state, const At& at, Output* out,
                  CancelReason reason);
  // Dart `_advanceCaptureGeneration`: the capture in flight becomes stale.
  void advance_generation() { scheduler_.advance_generation(); }
  // Teardown (Dart `_invalidateCaptureWork`): advances the generation,
  // resolves every request as cancelled, and stops waiting for the capture
  // in flight; its late answer is then ignored like any unknown id.
  void invalidate(EngineState* state, const At& at, Output* out,
                  CancelReason reason);

  // The host answered. Answers to unknown or stale ids are ignored, and a
  // frame no one accepts is released. An accepted frame runs the
  // frame-accepted hooks.
  void on_result(EngineState* state, const At& at, Output* out,
                 const CaptureResult& result);
  // `capture.due` fired.
  void on_due(EngineState* state, const At& at, Output* out);
  // Change C18: `capture.answer.<host_request_id>` fired. The capture still
  // in flight resolves as `paint_readiness_timeout` with failure
  // `answer_timeout`; a later answer to its id is ignored.
  void on_answer_deadline(EngineState* state, const At& at, Output* out,
                          const std::string& host_request_id);

  // A `surface` fact.
  void observe_surface(const BoundaryRect& rect, int64_t generation);
  const BoundaryObservation& boundary() const { return boundary_; }

  const FrameStore& frames() const { return frames_; }
  // The frame completion sequence: how many frames this session accepted.
  int64_t sequence() const { return frames_.sequence(); }
  const FrameProvenance* latest(const std::string& session_id) const {
    return frames_.latest(session_id);
  }
  const FrameProvenance* find(const std::string& frame_id) const {
    return frames_.find(frame_id);
  }
  OptString observed_after(const OptString& frame_id,
                           const ObservationBoundary& boundary) const {
    return frames_.observed_after(frame_id, boundary);
  }

  // Session-start seeds: align the initial capture with the visible route
  // until the first live push, pop, or replace.
  void restamp_initial_route_from_visible(EngineState* state);

 private:
  // Runs the queue head while nothing is in flight and it is due.
  void pump(EngineState* state, const At& at, Output* out);
  // Decision steps 1, 2 and the staleness check, then the request.
  void begin(EngineState* state, const At& at, Output* out,
             ScheduledCapture scheduled);
  void issue(InFlightCapture capture, EngineState* state, Output* out);
  static std::string answer_timer_id(const std::string& host_request_id);
  // Classifies the host's answer to the capture in flight.
  ExecutionResult execute(EngineState* state, const At& at, Output* out,
                          const InFlightCapture& flight,
                          const CaptureResult& result);
  ExecutionResult execute_captured(EngineState* state, const At& at,
                                   Output* out, const InFlightCapture& flight,
                                   const CapturedFrame& frame);
  // Dart `_captureContextStillCurrent`.
  bool still_current(const EngineState& state, const RequestContext& context,
                     int64_t generation) const;
  void charge(const At& at, int64_t cost_us, const EngineState& state);
  void release(const CapturedFrame& frame, Output* out) const;
  void arm_due(EngineState* state, int64_t at_mono_us, Output* out);

  // One `capture_execution-N` for every waiter of one execution.
  void resolve_execution(EngineState* state, const At& at, Output* out,
                         const std::vector<CaptureWaiter>& waiters,
                         const ExecutionResult& execution);
  // One `capture_execution-N` per waiter (cancellations, rejections).
  void resolve_each(EngineState* state, const At& at, Output* out,
                    const std::vector<CaptureWaiter>& waiters,
                    const ExecutionResult& execution);
  void resolve_waiter(EngineState* state, const At& at, Output* out,
                      const CaptureWaiter& waiter,
                      const std::string& execution_id,
                      const ExecutionResult& execution);
  // Whether the waiter's diagnostic is recorded without the
  // `captureDiagnostics` capability: host contract failures always, a
  // secure window once per route instance (counting the others).
  bool always_reported(const EngineState& state, const CaptureWaiter& waiter,
                       const ExecutionResult& execution);

  FrameStore frames_;
  CaptureScheduler scheduler_;
  CaptureBudget budget_;
  BoundaryObservation boundary_;
  SecureWindowLog secure_windows_;
  std::optional<int64_t> due_at_mono_us_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_SEAM_H
