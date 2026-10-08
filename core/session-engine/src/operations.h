// Message handlers. Each validates a message `input` object (at JSON path
// `$.input`) and builds the `result` object of the response. They reproduce
// the current Dart implementation exactly; see conformance/README.md.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_OPERATIONS_H
#define TUGBOAT_SESSION_ENGINE_OPERATIONS_H

#include "json.h"
#include "reader.h"

namespace tugboat {
namespace engine {

// `fingerprint.identityParts`: `_fingerprintForParts` in
// anchor_fingerprint.dart.
bool run_identity_parts(const Value& input, Value* result, Error* error);

// `fingerprint.labelHash`: `tugboatLabelHash`.
bool run_label_hash(const Value& input, Value* result, Error* error);

// `collector.event`: `mapTugboatEventToCollectorEvent`.
bool run_collector_event(const Value& input, Value* result, Error* error);

// `collector.sessionLifecycle`:
// `mapTugboatSessionLifecycleToCollectorSession`.
bool run_session_lifecycle(const Value& input, Value* result, Error* error);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_OPERATIONS_H
