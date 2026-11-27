#include "capture_seam.h"

#include <algorithm>
#include <utility>

#include "capture_diagnostics.h"
#include "coordination.h"
#include "engine_state.h"
#include "module_registry.h"
#include "navigation_view.h"

namespace tugboat {
namespace engine {

namespace {

// Dart `_captureFreshnessFor`.
CaptureFreshness freshness_for(FrameTrigger trigger, bool force) {
  const bool fresh = force || trigger == FrameTrigger::kInitial ||
                     trigger == FrameTrigger::kLifecycle ||
                     trigger == FrameTrigger::kTap ||
                     trigger == FrameTrigger::kInteraction;
  return fresh ? CaptureFreshness::kFreshPaint : CaptureFreshness::kReusable;
}

// Dart `_isEligibleForBudgetSkip` (with `skipEligibleWhenDegraded` on).
bool budget_skips(const ScheduledCapture& scheduled, bool degraded) {
  return degraded && scheduled.freshness == CaptureFreshness::kReusable &&
         scheduled.trigger != FrameTrigger::kInitial &&
         scheduled.trigger != FrameTrigger::kLifecycle;
}

ExecutionResult with_backend(ExecutionResult execution,
                             const CapturedFrame& frame) {
  execution.requested_backend = frame.requested_backend;
  execution.resolved_backend = frame.resolved_backend;
  execution.fallback_reason = frame.fallback_reason;
  return execution;
}

int64_t elapsed_us(int64_t from_mono_us, int64_t to_mono_us) {
  return std::max<int64_t>(to_mono_us - from_mono_us, 0);
}

}  // namespace

CaptureAsk interaction_capture(const std::string& related_event_id) {
  CaptureAsk ask;
  ask.trigger = FrameTrigger::kInteraction;
  ask.force = true;
  ask.related_event_id = related_event_id;
  return ask;
}

void CaptureSeam::reset() {
  frames_.reset();
  boundary_ = BoundaryObservation{};
  secure_windows_.reset();
}

void CaptureSeam::report_secure_windows(EngineState* state, const At& at,
                                        Output* out) {
  secure_windows_.report(state, at, out);
}

// ------------------------------------------------------------- requests

std::string CaptureSeam::request(Turn& turn, const CaptureOwner& owner,
                                 const CaptureAsk& ask) {
  EngineState* state = turn.state;
  CaptureWaiter waiter;
  waiter.request_id = state->ids.next("capture_request");
  waiter.context = current_request_context(*state, ask.trigger);
  waiter.owner = owner;
  waiter.related_event_id = ask.related_event_id;
  const std::string request_id = waiter.request_id;
  // Dart `_requestCaptureIsSuppressed` (change C11: per navigator).
  if (transition_suppresses(*state, waiter.context.navigator_id)) {
    resolve_each(state, turn.at, turn.out, {waiter},
                 cancelled_execution(CancelReason::kRouteTransition));
    return request_id;
  }
  if (ask.drop_when_busy && scheduler_.busy()) {
    charge(turn.at, 0, *state);
    ExecutionResult dropped;
    dropped.outcome = CaptureOutcome::kCapturePressureDrop;
    dropped.cancellation = CancelReason::kCapturePressure;
    resolve_each(state, turn.at, turn.out, {waiter}, dropped);
    return request_id;
  }
  ScheduledCapture scheduled;
  scheduled.trigger = ask.trigger;
  scheduled.force = ask.force;
  scheduled.freshness = freshness_for(ask.trigger, ask.force);
  scheduled.drop_when_busy = ask.drop_when_busy;
  scheduled.not_before_mono_us = turn.at.mono_us + ask.settle_delay_ms * 1000;
  scheduled.enqueued_mono_us = turn.at.mono_us;
  scheduled.context = waiter.context;
  scheduled.waiters.push_back(std::move(waiter));
  scheduler_.enqueue(std::move(scheduled));
  pump(state, turn.at, turn.out);
  return request_id;
}

void CaptureSeam::cancel(EngineState* state, const At& at, Output* out,
                         const std::string& request_id, CancelReason reason) {
  std::optional<CaptureWaiter> waiter = scheduler_.remove_waiter(request_id);
  if (!waiter) return;
  resolve_each(state, at, out, {*waiter}, cancelled_execution(reason));
}

void CaptureSeam::cancel_all(EngineState* state, const At& at, Output* out,
                             CancelReason reason) {
  resolve_each(state, at, out, scheduler_.take_all_waiters(false),
               cancelled_execution(reason));
}

void CaptureSeam::invalidate(EngineState* state, const At& at, Output* out,
                             CancelReason reason) {
  scheduler_.advance_generation();
  if (const InFlightCapture* flight = scheduler_.in_flight()) {
    state->timers.cancel(answer_timer_id(flight->host_request_id), out);
  }
  resolve_each(state, at, out, scheduler_.take_all_waiters(true),
               cancelled_execution(reason));
  if (due_at_mono_us_) {
    state->timers.cancel(kCaptureDueTimerId, out);
    due_at_mono_us_.reset();
  }
}

// ------------------------------------------------------------ execution

void CaptureSeam::on_due(EngineState* state, const At& at, Output* out) {
  due_at_mono_us_.reset();
  pump(state, at, out);
}

void CaptureSeam::pump(EngineState* state, const At& at, Output* out) {
  while (scheduler_.in_flight() == nullptr && scheduler_.head() != nullptr) {
    const int64_t not_before = scheduler_.head()->not_before_mono_us;
    if (not_before > at.mono_us) {
      arm_due(state, not_before, out);
      return;
    }
    begin(state, at, out, scheduler_.take_head());
  }
}

void CaptureSeam::arm_due(EngineState* state, int64_t at_mono_us,
                          Output* out) {
  if (due_at_mono_us_ && *due_at_mono_us_ == at_mono_us) return;
  due_at_mono_us_ = at_mono_us;
  state->timers.schedule(kCaptureDueTimerId, at_mono_us, out);
}

void CaptureSeam::begin(EngineState* state, const At& at, Output* out,
                        ScheduledCapture scheduled) {
  const int64_t queue_wait_us = elapsed_us(scheduled.enqueued_mono_us,
                                           at.mono_us);
  scheduled.context.trigger = scheduled.trigger;
  const RequestContext& context = scheduled.context;
  // 1. Suppressed while the context's navigator is in a transition.
  if (transition_suppresses(*state, context.navigator_id)) {
    resolve_execution(state, at, out, scheduled.waiters,
                      cancelled_execution(CancelReason::kRouteTransition));
    return;
  }
  // 2. Budget skip: a degraded, reusable capture reuses a compatible frame.
  const bool has_compatible = frames_.compatible_latest(context) != nullptr;
  if (has_compatible && budget_skips(scheduled, budget_.degraded())) {
    charge(at, queue_wait_us, *state);
    resolve_execution(
        state, at, out, scheduled.waiters,
        reuse_compatible(&frames_, context,
                         CaptureOutcome::kScreenshotBudgetSkip, "budget"));
    return;
  }
  // A context that is no longer current never reaches the host.
  if (!still_current(*state, context, scheduler_.generation())) {
    resolve_execution(state, at, out, scheduled.waiters,
                      cancelled_execution(CancelReason::kSupersededRoute));
    return;
  }
  InFlightCapture flight;
  flight.generation = scheduler_.generation();
  flight.queue_wait_us = queue_wait_us;
  flight.issued_mono_us = at.mono_us;
  // Dart: a forced capture never skips an unchanged paint or coalesces.
  flight.forced = scheduled.force ||
                  scheduled.freshness == CaptureFreshness::kFreshPaint ||
                  !has_compatible;
  if (!flight.forced) flight.baseline = frames_.dhash_baseline();
  flight.capture = std::move(scheduled);
  issue(std::move(flight), state, out);
}

void CaptureSeam::issue(InFlightCapture flight, EngineState* state,
                        Output* out) {
  const ScheduledCapture& scheduled = flight.capture;
  flight.host_request_id = scheduler_.next_host_request_id();
  CaptureRequest request;
  request.request_id = flight.host_request_id;
  request.trigger = scheduled.trigger;
  request.force = flight.forced;
  request.require_fresh_paint =
      scheduled.freshness == CaptureFreshness::kFreshPaint;
  request.drop_when_busy = scheduled.drop_when_busy;
  request.not_before_mono_us = scheduled.not_before_mono_us;
  request.context = scheduled.context.effect_context();
  request.dhash_baseline = flight.baseline;
  request.scale =
      budget_.degraded() ? state->config.capture.degraded_scale : 1.0;
  out->effects.push_back(std::move(request));
  // Change C18: the answer is due within answerTimeoutMs of the request.
  state->timers.schedule(
      answer_timer_id(flight.host_request_id),
      flight.issued_mono_us + state->config.capture.answer_timeout_ms * 1000,
      out);
  scheduler_.start(std::move(flight));
}

std::string CaptureSeam::answer_timer_id(const std::string& host_request_id) {
  return kCaptureAnswerTimerPrefix + host_request_id;
}

void CaptureSeam::on_answer_deadline(EngineState* state, const At& at,
                                     Output* out,
                                     const std::string& host_request_id) {
  InFlightCapture* flight = scheduler_.in_flight();
  if (flight == nullptr || flight->host_request_id != host_request_id) {
    return;
  }
  const InFlightCapture done = *scheduler_.finish();
  charge(at, done.queue_wait_us + (at.mono_us - done.issued_mono_us),
         *state);
  // Dart's frame wait timeout outcome, marked as the host's failure.
  ExecutionResult timeout;
  timeout.outcome = CaptureOutcome::kPaintReadinessTimeout;
  timeout.host_failure = HostFailure::kAnswerTimeout;
  if (done.capture.waiters.empty()) {
    // Every request it served was cancelled: report the execution itself.
    CaptureWaiter execution;
    execution.context = done.capture.context;
    resolve_execution(state, at, out, {execution}, timeout);
  } else {
    resolve_execution(state, at, out, done.capture.waiters, timeout);
  }
  pump(state, at, out);
}

void CaptureSeam::on_result(EngineState* state, const At& at, Output* out,
                            const CaptureResult& result) {
  InFlightCapture* flight = scheduler_.in_flight();
  if (flight == nullptr || flight->host_request_id != result.request_id ||
      state->live_session() == nullptr) {
    if (result.frame) release(*result.frame, out);
    return;
  }
  state->timers.cancel(answer_timer_id(flight->host_request_id), out);
  const ExecutionResult execution = execute(state, at, out, *flight, result);
  const InFlightCapture done = *scheduler_.finish();
  resolve_execution(state, at, out, done.capture.waiters, execution);
  pump(state, at, out);
}

ExecutionResult CaptureSeam::execute(EngineState* state, const At& at,
                                     Output* out,
                                     const InFlightCapture& flight,
                                     const CaptureResult& result) {
  const RequestContext& context = flight.capture.context;
  const bool current = still_current(*state, context, flight.generation);
  if (!current) {
    if (result.frame) release(*result.frame, out);
    ExecutionResult stale;
    stale.outcome = CaptureOutcome::kSupersededRoute;
    if (result.outcome == CaptureResultOutcome::kCancelled) {
      stale.cancellation = CancelReason::kSupersededRoute;
    }
    return stale;
  }
  switch (result.outcome) {
    case CaptureResultOutcome::kCaptured:
      charge(at,
             flight.queue_wait_us +
                 (result.timings ? result.timings->total()
                                 : result.frame->capture_micros),
             *state);
      return execute_captured(state, at, out, flight, *result.frame);
    case CaptureResultOutcome::kPaintUnchanged: {
      // A forced request must be captured: answering it unchanged breaks
      // the host contract.
      if (flight.forced) {
        ExecutionResult violation;
        violation.outcome = CaptureOutcome::kCaptureProcessingFailed;
        violation.host_failure = HostFailure::kContractViolation;
        return violation;
      }
      // Dart retries a paint-unchanged attempt once, forced, when no
      // compatible frame is left to reuse. Here the latest frame only
      // changes when a capture resolves and one capture is in flight, so
      // the frame compatible at the request still is.
      return reuse_compatible(&frames_, context,
                              CaptureOutcome::kPaintGenerationUnchanged,
                              "paint_generation");
    }
    case CaptureResultOutcome::kFailed: {
      charge(at,
             flight.queue_wait_us +
                 (result.timings ? result.timings->frame_wait_us : 0),
             *state);
      return failed_execution(result.failure);
    }
    case CaptureResultOutcome::kCancelled:
      break;
  }
  ExecutionResult cancelled;
  cancelled.outcome = CaptureOutcome::kCancelled;
  cancelled.cancellation = CancelReason::kSupersededRoute;
  return cancelled;
}

ExecutionResult CaptureSeam::execute_captured(EngineState* state,
                                              const At& at, Output* out,
                                              const InFlightCapture& flight,
                                              const CapturedFrame& frame) {
  const RequestContext& context = flight.capture.context;
  const CapturedClassification classification =
      classify_captured(frames_, flight, frame);
  switch (classification.disposition) {
    case CapturedDisposition::kCoalesced: {
      release(frame, out);
      // The baselines stay those of the frame that is referenced.
      ExecutionResult coalesced = reuse_compatible(
          &frames_, context, CaptureOutcome::kPerceptualHashCoalesced,
          "dhash");
      return with_backend(std::move(coalesced), frame);
    }
    case CapturedDisposition::kContentReused: {
      release(frame, out);
      ExecutionResult reused;
      reused.outcome = CaptureOutcome::kExactContentReused;
      reused.frame_id = frames_.reuse(classification.reuse_frame_id, context);
      reused.reuse_reason = std::string("content_hash");
      frames_.commit_baselines(frame);
      return with_backend(std::move(reused), frame);
    }
    case CapturedDisposition::kAccepted:
      break;
  }
  if (frame.boundary) boundary_.rect = frame.boundary;
  Session& session = *state->live_session();
  const FrameRecord record = frames_.accept(
      frame, context, session.at_ms(at.mono_us),
      state->config.limits.max_frames, &state->ids, &session,
      &state->frame_retention, out);
  // Right after the frame record, before the frame-accepted hooks can
  // record anything (a delivery eviction gap).
  if (frame.mask_coverage) {
    record_mask_coverage(state, at, out, record.frame.id,
                         *frame.mask_coverage);
  }
  // The registry of the message being applied (engine.cpp).
  if (const ModuleRegistry* modules = state->applying.modules) {
    modules->run_frame_accepted(record.frame, record.handle, state, out);
  }
  ExecutionResult accepted;
  accepted.outcome = CaptureOutcome::kFreshAccepted;
  accepted.frame_id = record.frame.id;
  return with_backend(std::move(accepted), frame);
}

bool CaptureSeam::still_current(const EngineState& state,
                                const RequestContext& context,
                                int64_t generation) const {
  const NavigationState& navigation = state.navigation;
  return generation == scheduler_.generation() && state.session &&
         context.session_id == state.session->id() &&
         context.route_epoch == navigation.route_epoch &&
         context.route == navigation.visible.route &&
         context.boundary_generation == boundary_.generation;
}

void CaptureSeam::charge(const At& at, int64_t cost_us,
                         const EngineState& state) {
  const CaptureConfig& config = state.config.capture;
  budget_.record(at.mono_us, cost_us, config.budget_window_ms * 1000,
                 config.budget_ms * 1000);
}

void CaptureSeam::release(const CapturedFrame& frame, Output* out) const {
  out->effects.push_back(FrameRelease{frame.handle});
}

void CaptureSeam::observe_surface(const BoundaryRect& rect,
                                  int64_t generation) {
  boundary_.rect = rect;
  boundary_.generation = generation;
}

// ------------------------------------------------------------ resolution

bool CaptureSeam::always_reported(const EngineState& state,
                                  const CaptureWaiter& waiter,
                                  const ExecutionResult& execution) {
  // Host contract problems are always reported, so hosts can count them.
  if (execution.host_failure) return true;
  // With the capability every resolution is recorded: nothing to throttle.
  if (!execution.secure_window ||
      state.config.capabilities.capture_diagnostics) {
    return false;
  }
  return secure_windows_.first(waiter.context.route_instance_id);
}

void CaptureSeam::resolve_execution(EngineState* state, const At& at,
                                    Output* out,
                                    const std::vector<CaptureWaiter>& waiters,
                                    const ExecutionResult& execution) {
  // Dart mints the execution id even when every waiter was cancelled.
  const std::string execution_id = state->ids.next("capture_execution");
  for (const CaptureWaiter& waiter : waiters) {
    resolve_waiter(state, at, out, waiter, execution_id,
                   for_waiter(frames_, execution, waiter.context));
  }
}

void CaptureSeam::resolve_each(EngineState* state, const At& at, Output* out,
                               const std::vector<CaptureWaiter>& waiters,
                               const ExecutionResult& execution) {
  for (const CaptureWaiter& waiter : waiters) {
    resolve_waiter(state, at, out, waiter,
                   state->ids.next("capture_execution"), execution);
  }
}

void CaptureSeam::resolve_waiter(EngineState* state, const At& at,
                                 Output* out, const CaptureWaiter& waiter,
                                 const std::string& execution_id,
                                 const ExecutionResult& execution) {
  record_capture_diagnostic(state, at, out, waiter, execution_id, execution,
                            always_reported(*state, waiter, execution));
  if (waiter.owner.kind == CaptureOwner::Kind::kNone) return;
  defer(state, CaptureAnswer{waiter.owner,
                             CaptureResolution{waiter.request_id,
                                               execution.outcome,
                                               execution.frame_id}});
}

void CaptureSeam::restamp_initial_route(EngineState* state) {
  const VisibleRoute& visible = state->navigation.visible;
  scheduler_.restamp_initial_route(visible);
  frames_.restamp_initial_route(visible);
}

}  // namespace engine
}  // namespace tugboat
