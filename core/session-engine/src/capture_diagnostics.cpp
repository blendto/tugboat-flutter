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
  } else if (execution.secure_window) {
    data.set("failure", Value::string("secure_window"));
  }
  if (waiter.coalesced) data.set("coalesced", Value::boolean(true));
  // The backend trace the host reported with its frame.
  put_opt(&data, "requestedBackend", execution.requested_backend);
  put_opt(&data, "resolvedBackend", execution.resolved_backend);
  put_opt(&data, "fallbackReason", execution.fallback_reason);
  return data;
}

}  // namespace

bool SecureWindowLog::first(const OptString& route_instance_id) {
  for (auto& route : routes_) {
    if (route.first == route_instance_id) {
      ++route.second;
      return false;
    }
  }
  routes_.emplace_back(route_instance_id, 0);
  return true;
}

void SecureWindowLog::report(EngineState* state, const At& at, Output* out) {
  for (auto& route : routes_) {
    if (route.second == 0) continue;
    Diagnostic summary;
    summary.data.set("component", Value::string("capture_secure_window"));
    put_opt(&summary.data, "routeInstanceId", route.first);
    summary.data.set("repeatCount", Value::integer(route.second));
    if (!record_diagnostic(state, at, out, std::move(summary))) return;
    route.second = 0;
  }
}

void record_capture_diagnostic(EngineState* state, const At& at, Output* out,
                               const CaptureWaiter& waiter,
                               const std::string& execution_id,
                               const ExecutionResult& execution, bool always) {
  if (!always && !state->config.capabilities.capture_diagnostics) return;
  Diagnostic diagnostic;
  diagnostic.after_frame = execution.frame_id;
  diagnostic.data = diagnostic_data(waiter, execution_id, execution);
  record_diagnostic(state, at, out, std::move(diagnostic));
}

void record_mask_coverage(EngineState* state, const At& at, Output* out,
                          const std::string& frame_id,
                          const MaskCoverage& coverage) {
  Value reasons = Value::array();
  for (MaskReason reason : coverage.reasons) {
    reasons.push(Value::string(mask_reason_name(reason)));
  }
  Diagnostic diagnostic;
  diagnostic.after_frame = frame_id;
  diagnostic.data.set("component", Value::string("capture_masking"));
  diagnostic.data.set("frameId", Value::string(frame_id));
  diagnostic.data.set("mode", Value::string(mask_mode_name(coverage.mode)));
  diagnostic.data.set("reasons", std::move(reasons));
  record_diagnostic(state, at, out, std::move(diagnostic));
}

}  // namespace engine
}  // namespace tugboat
