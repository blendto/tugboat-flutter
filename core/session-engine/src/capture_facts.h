// The capture facts of docs/stateful-engine.md section 8.2 (the host's
// `capture.result` answer and the adapter's `surface` report), with their
// strict decoders. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_FACTS_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_FACTS_H

#include <cstdint>
#include <string>

#include "capture_types.h"
#include "json.h"
#include "reader.h"

namespace tugboat {
namespace engine {

// `surface {boundaryRect, generation}`: the capture boundary moved or was
// replaced. `generation` is the adapter's boundary transform generation
// (Dart `_boundaryTransformGeneration`): it advances whenever the boundary's
// logical rect changes.
struct SurfaceFact {
  BoundaryRect boundary;
  int64_t generation = 0;
};

// `capture.result`: `frame` (and optionally `boundaryRect`) is required
// with `captured` and not allowed otherwise; `failure` is allowed with
// `failed` only; `timings` with any outcome. `frame.maskCoverage {mode,
// reasons}` is optional; its vocabularies are closed and `reasons` holds
// at most kMaxMaskReasons distinct names.
bool decode_capture_result(const Value& input, const std::string& path,
                           CaptureResult* out, Error* error);
bool decode_surface_fact(const Value& input, const std::string& path,
                         SurfaceFact* out, Error* error);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_FACTS_H
