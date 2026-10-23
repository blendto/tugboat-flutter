// What one capture execution resolves to (Dart `_CaptureExecution` and the
// decision order of `_executeCapture`, docs/stateful-engine.md section 8.2):
//
//   1. suppressed            route_transition (change C11: per navigator)
//   2. budget skip           a degraded, reusable capture reuses a frame
//   3. paint-unchanged reuse the host saw no new paint
//   4. dHash coalescing      the host matched the offered baseline
//   5. exact-content reuse   a retained frame has the same content hash
//                            and mask coverage (change C21)
//   6. fresh_accepted        a new `frame-N`
//
// Steps 1, 2, and the staleness check run before the host is asked
// (capture_seam.cpp); steps 3 to 6 classify the host's answer. Each waiter
// then gets its own view of the execution (`for_waiter`).
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_EXECUTION_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_EXECUTION_H

#include <optional>

#include "capture_scheduler.h"
#include "capture_types.h"
#include "frame_store.h"
#include "models.h"

namespace tugboat {
namespace engine {

// A host contract problem the engine detected (no Dart counterpart). It is
// always reported as a `capture_diagnostic` `failure`.
enum class HostFailure {
  kAnswerTimeout,      // change C18: no answer before the deadline
  kContractViolation,  // `paintUnchanged` answered to a forced request
};

const char* host_failure_name(HostFailure failure);

// Dart `_CaptureExecution`.
struct ExecutionResult {
  CaptureOutcome outcome = CaptureOutcome::kNoFrameAvailable;
  OptString frame_id;
  std::optional<CancelReason> cancellation;
  // `budget`, `paint_generation`, `dhash`, or `content_hash`.
  OptString reuse_reason;
  std::optional<HostFailure> host_failure;
  // The host refused to copy a secure window (`failed` with
  // `secureWindow`): a `capture_diagnostic` `failure: secure_window`,
  // reported without the `captureDiagnostics` capability once per route
  // instance (capture_diagnostics.h).
  bool secure_window = false;
  // The backend trace of the frame the host captured, if any.
  OptString requested_backend;
  OptString resolved_backend;
  OptString fallback_reason;
};

// Dart `_cancelledCaptureExecution`: `superseded_route` resolves as
// `superseded_route_epoch`, every other reason as `cancelled`.
ExecutionResult cancelled_execution(CancelReason reason);

// Dart `_reuseWithoutCapture`: the latest frame when it is compatible with
// `context` (it stays the latest), else `no_compatible_frame`.
ExecutionResult reuse_compatible(FrameStore* frames,
                                 const RequestContext& context,
                                 CaptureOutcome outcome,
                                 const char* reuse_reason);

// Dart `_diagnosticOutcomeForFailure` for a host `failed` answer; no reason
// is a processing failure.
CaptureOutcome failure_outcome(const std::optional<CaptureFailure>& failure);

// A host `failed` answer: its `failure_outcome`, flagged `secure_window`
// for `secureWindow`.
ExecutionResult failed_execution(const std::optional<CaptureFailure>& failure);

// How a `captured` answer resolves (steps 4 to 6).
enum class CapturedDisposition {
  kCoalesced,      // the frame matched the offered dHash baseline
  kContentReused,  // a compatible retained frame has the same content and
                   // mask coverage (change C21)
  kAccepted,       // a new frame
};

// Dart `_reusePhysicalCaptureResult`. A perceptual match counts only when
// the engine offered a baseline and the host reports that baseline's dHash
// under the same visible structure.
CapturedDisposition classify_captured(const FrameStore& frames,
                                      const InFlightCapture& capture,
                                      const CapturedFrame& frame);

// Dart `_executionForCaptureWaiter`: a waiter keeps the frame only when it
// is compatible with the waiter's own context.
ExecutionResult for_waiter(const FrameStore& frames,
                           const ExecutionResult& execution,
                           const RequestContext& waiter_context);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_EXECUTION_H
