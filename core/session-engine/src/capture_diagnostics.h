// The `capture_diagnostic` events of the capture seam:
//
// - one per resolved capture request (Dart `_recordCaptureDiagnostic`): a
//   bounded, privacy-safe record of how the request resolved, recorded
//   with the `captureDiagnostics` capability, always for a host contract
//   failure (C18), and for the first secure window of a route instance;
// - `capture_masking`: the mask coverage of an accepted native frame,
//   always recorded;
// - `capture_secure_window`: how many later secure-window failures of a
//   route instance went unrecorded.
//
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_DIAGNOSTICS_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_DIAGNOSTICS_H

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "capture_execution.h"
#include "capture_scheduler.h"
#include "capture_types.h"
#include "clock.h"
#include "models.h"
#include "output.h"

namespace tugboat {
namespace engine {

struct EngineState;

// Throttles the secure-window diagnostic that is recorded without the
// `captureDiagnostics` capability, so a secure screen captured again and
// again cannot flood the event queue: per session, only the first
// `secureWindow` failure of each route instance (or of the session before
// any route) is recorded. Later ones are counted and reported at the next
// teardown (going to the background, session end or replacement) as one
// `capture_diagnostic {component: capture_secure_window, routeInstanceId?,
// repeatCount}` per route instance with uncounted repeats.
class SecureWindowLog {
 public:
  // True for the first failure of `route_instance_id` this session; counts
  // every later one.
  bool first(const OptString& route_instance_id);
  // Records the repeat counts since the last report and zeroes them. A
  // route instance stays throttled for the rest of the session.
  void report(EngineState* state, const At& at, Output* out);
  // Session start: forgets every route instance.
  void reset() { routes_.clear(); }

 private:
  // Route instances seen, in first-failure order, with their repeats.
  std::vector<std::pair<OptString, int64_t>> routes_;
};

// Records the diagnostic of `waiter` resolving as `execution` under
// `execution_id` while a session is live: with the `captureDiagnostics`
// capability, or when `always` (a host contract failure, or a first
// secure window). A waiter without a request id (an execution no request
// waits for any more) has no `requestId`.
void record_capture_diagnostic(EngineState* state, const At& at, Output* out,
                               const CaptureWaiter& waiter,
                               const std::string& execution_id,
                               const ExecutionResult& execution, bool always);

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
