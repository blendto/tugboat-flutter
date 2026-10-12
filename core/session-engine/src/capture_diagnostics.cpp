#include "capture_diagnostics.h"

#include <utility>

#include "engine_state.h"
#include "recorder.h"

namespace tugboat {
namespace engine {

namespace {

const char* visual_evidence(const ExecutionResult& execution) {
  if (!execution.frame_id) return "unavailable";
  return execution.outcome == CaptureOutcome::kFreshAccepted ? "fresh"
                                                             : "reused";
}

Value diagnostic_data(const CaptureWaiter& waiter,
                      const std::string& execution_id,
                      const ExecutionResult& execution) {
  const RequestContext& context = waiter.context;
  Value data = Value::object();
  data.set("version", Value::integer(1));
  data.set("outcome", Value::string(capture_outcome_name(execution.outcome)));
  if (!waiter.request_id.empty()) {
    data.set("requestId", Value::string(waiter.request_id));
  }
  data.set("executionId", Value::string(execution_id));
  data.set("captureSessionId", Value::string(context.session_id));
  data.set("routeEpoch", Value::integer(context.route_epoch));
  put_opt(&data, "navigatorId", context.navigator_id);
  put_opt(&data, "routeInstanceId", context.route_instance_id);
  data.set("trigger", Value::string(frame_trigger_name(context.trigger)));
  data.set("visualEvidence", Value::string(visual_evidence(execution)));
  data.set("interactionEvidence",
           Value::string(waiter.related_event_id ? "linked"
                                                 : "not_applicable"));
  put_opt(&data, "relatedEventId", waiter.related_event_id);
  if (execution.cancellation) {
    data.set("cancellationReason",
             Value::string(cancel_reason_name(*execution.cancellation)));
  }
  put_opt(&data, "reuseReason", execution.reuse_reason);
  if (execution.host_failure) {
    data.set("failure",
             Value::string(host_failure_name(*execution.host_failure)));
  }
  if (waiter.coalesced) data.set("coalesced", Value::boolean(true));
  // The backend trace the host reported with its frame.
  put_opt(&data, "requestedBackend", execution.requested_backend);
  put_opt(&data, "resolvedBackend", execution.resolved_backend);
  put_opt(&data, "fallbackReason", execution.fallback_reason);
  return data;
}

}  // namespace

void record_capture_diagnostic(EngineState* state, const At& at, Output* out,
                               const CaptureWaiter& waiter,
                               const std::string& execution_id,
                               const ExecutionResult& execution) {
  Session* session = state->live_session();
  // Host contract problems are always reported, so hosts can count them.
  const bool enabled = state->config.capabilities.capture_diagnostics ||
                       execution.host_failure.has_value();
  if (session == nullptr || !enabled) return;
  Event event = make_event(state, *session, "capture_diagnostic", at.mono_us);
  event.stream = EventStream::kDiagnostic;
  event.after_frame = execution.frame_id;
  event.data = diagnostic_data(waiter, execution_id, execution);
  record_event(state, *session, std::move(event), true, out);
}

void record_mask_coverage(EngineState* state, const At& at, Output* out,
                          const std::string& frame_id,
                          const MaskCoverage& coverage) {
  Session* session = state->live_session();
  if (session == nullptr) return;
  Value reasons = Value::array();
  for (MaskReason reason : coverage.reasons) {
    reasons.push(Value::string(mask_reason_name(reason)));
  }
  Value data = Value::object();
  data.set("component", Value::string("capture_masking"));
  data.set("frameId", Value::string(frame_id));
  data.set("mode", Value::string(mask_mode_name(coverage.mode)));
  data.set("reasons", std::move(reasons));
  Event event = make_event(state, *session, "capture_diagnostic", at.mono_us);
  event.stream = EventStream::kDiagnostic;
  event.after_frame = frame_id;
  event.data = std::move(data);
  record_event(state, *session, std::move(event), true, out);
}

}  // namespace engine
}  // namespace tugboat
