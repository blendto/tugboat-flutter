// The `capture_diagnostic` event of one resolved capture request (Dart
// `_recordCaptureDiagnostic`): a bounded, privacy-safe record of how the
// request resolved, emitted only with the `captureDiagnostics` capability.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_DIAGNOSTICS_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_DIAGNOSTICS_H

#include <string>

#include "capture_execution.h"
#include "capture_scheduler.h"
#include "clock.h"
#include "output.h"

namespace tugboat {
namespace engine {

struct EngineState;

// Records the diagnostic of `waiter` resolving as `execution` under
// `execution_id`, when the capability is on and a session is live.
void record_capture_diagnostic(EngineState* state, const At& at, Output* out,
                               const CaptureWaiter& waiter,
                               const std::string& execution_id,
                               const ExecutionResult& execution);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_DIAGNOSTICS_H
