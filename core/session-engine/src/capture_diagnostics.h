// The `capture_diagnostic` events of the capture seam:
//
// - one per resolved capture request (Dart `_recordCaptureDiagnostic`): a
//   bounded, privacy-safe record of how the request resolved, emitted with
//   the `captureDiagnostics` capability and always for a host failure;
// - `capture_masking`: the mask coverage of an accepted native frame,
//   always emitted.
//
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_DIAGNOSTICS_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_DIAGNOSTICS_H

#include <string>

#include "capture_execution.h"
#include "capture_scheduler.h"
#include "capture_types.h"
#include "clock.h"
#include "output.h"

namespace tugboat {
namespace engine {

struct EngineState;

// Records the diagnostic of `waiter` resolving as `execution` under
// `execution_id` while a session is live: with the `captureDiagnostics`
// capability, and always for a host failure (C18 answer timeouts, contract
// violations, secure windows). A waiter without a request id (an execution no request waits
// for any more) has no `requestId`.
void record_capture_diagnostic(EngineState* state, const At& at, Output* out,
                               const CaptureWaiter& waiter,
                               const std::string& execution_id,
                               const ExecutionResult& execution);

// Records the `capture_diagnostic` `{component: capture_masking, frameId,
// mode, reasons}` of a frame the engine just accepted as `frame_id` with
// the host's `maskCoverage`, while a session is live. Always recorded,
// with or without the `captureDiagnostics` capability, so a whole-masked
// frame can be told from a broken capture.
void record_mask_coverage(EngineState* state, const At& at, Output* out,
                          const std::string& frame_id,
                          const MaskCoverage& coverage);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_DIAGNOSTICS_H
