#include "capture_execution.h"

namespace tugboat {
namespace engine {

const char* host_failure_name(HostFailure failure) {
  return failure == HostFailure::kAnswerTimeout ? "answer_timeout"
                                                : "contract_violation";
}

ExecutionResult failed_execution(const std::optional<CaptureFailure>& failure) {
  ExecutionResult failed;
  failed.outcome = failure_outcome(failure);
  failed.secure_window = failure == CaptureFailure::kSecureWindow;
  return failed;
}

ExecutionResult cancelled_execution(CancelReason reason) {
  ExecutionResult execution;
  execution.outcome = reason == CancelReason::kSupersededRoute
                          ? CaptureOutcome::kSupersededRoute
                          : CaptureOutcome::kCancelled;
  execution.cancellation = reason;
  return execution;
}

ExecutionResult reuse_compatible(FrameStore* frames,
                                 const RequestContext& context,
                                 CaptureOutcome outcome,
                                 const char* reuse_reason) {
  ExecutionResult execution;
  const FrameProvenance* compatible = frames->compatible_latest(context);
  if (compatible == nullptr) {
    execution.outcome = CaptureOutcome::kNoCompatibleFrame;
    return execution;
  }
  execution.outcome = outcome;
  execution.frame_id = frames->reuse(compatible->frame_id, context);
  execution.reuse_reason = std::string(reuse_reason);
  return execution;
}

CaptureOutcome failure_outcome(const std::optional<CaptureFailure>& failure) {
  if (!failure) return CaptureOutcome::kCaptureProcessingFailed;
  switch (*failure) {
    case CaptureFailure::kPaintTimedOut:
    case CaptureFailure::kPaintNotAdvanced:
      return CaptureOutcome::kPaintReadinessTimeout;
    case CaptureFailure::kBoundaryUnavailable:
    case CaptureFailure::kBoundaryDetached:
    case CaptureFailure::kBoundaryReplaced:
    case CaptureFailure::kLayoutUnavailable:
      return CaptureOutcome::kBoundaryUnavailable;
    case CaptureFailure::kReadbackFailed:
    case CaptureFailure::kMaskFailed:
    case CaptureFailure::kEncodingFailed:
    case CaptureFailure::kSecureWindow:
      return CaptureOutcome::kCaptureProcessingFailed;
  }
  return CaptureOutcome::kCaptureProcessingFailed;
}

CapturedDisposition classify_captured(const FrameStore& frames,
                                      const InFlightCapture& capture,
                                      const CapturedFrame& frame) {
  const std::optional<DHashBaseline>& baseline = capture.baseline;
  if (baseline && frame.dhash == baseline->dhash &&
      frame.structure_signature == baseline->structure_signature) {
    return CapturedDisposition::kCoalesced;
  }
  const ScheduledCapture& scheduled = capture.capture;
  const OptString existing = frames.frame_with_content(frame.content_hash);
  if (!scheduled.force &&
      scheduled.freshness == CaptureFreshness::kReusable && existing &&
      frames.is_compatible(*existing, scheduled.context)) {
    return CapturedDisposition::kContentReused;
  }
  return CapturedDisposition::kAccepted;
}

ExecutionResult for_waiter(const FrameStore& frames,
                           const ExecutionResult& execution,
                           const RequestContext& waiter_context) {
  ExecutionResult own = execution;
  if (!execution.frame_id ||
      frames.is_compatible(*execution.frame_id, waiter_context)) {
    return own;
  }
  own.frame_id.reset();
  own.outcome = frames.has_latest() ? CaptureOutcome::kNoCompatibleFrame
                                    : CaptureOutcome::kNoFrameAvailable;
  return own;
}

}  // namespace engine
}  // namespace tugboat
