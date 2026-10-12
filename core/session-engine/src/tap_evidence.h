// Tap evidence that travels on a pointer fact (docs/stateful-engine.md
// section 9.1, principle 2): the adapter resolves the target at the down
// position against its live tree and attaches it, because by the time the
// engine decides the gesture is a tap the tree may have changed. The engine
// keeps the evidence only when the gesture stays a tap.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_TAP_EVIDENCE_H
#define TUGBOAT_SESSION_ENGINE_TAP_EVIDENCE_H

#include <optional>
#include <string>

#include "json.h"
#include "models.h"
#include "reader.h"

namespace tugboat {
namespace engine {

struct Turn;
struct Transaction;

// Dart `TugboatTargetResolutionFailureReason`.
enum class TapFailureReason {
  kNoTargetAtPoint,
  kNoSceneInventory,
  kNoActionableCandidate,
  kOutsideCaptureBoundary,
  kStaleRouteGeneration,
  kOpaquePlatformView,
  kSystemUi,
  kResolutionError,
};

const char* tap_failure_reason_name(TapFailureReason reason);

// The scene inventory the adapter built for the tap target. `json` is the
// `scene_inventory` event data (`TugboatSceneInventory.toJson()`); the route
// key and hash are its dedupe key.
struct TapInventory {
  std::string route_key;
  std::string inventory_hash;
  Value json;
};

// `tap {anchor?, failureReason?, inventory?}`.
struct TapEvidence {
  std::optional<Anchor> anchor;
  std::optional<TapFailureReason> failure_reason;
  std::optional<TapInventory> inventory;
};

// Decodes `tap` at `path`.
bool decode_tap_evidence(const Value& json, const std::string& path,
                         TapEvidence* out, Error* error);

// Dart `_resolveTapEvidence` at pointer-up of a gesture that stayed a tap.
// With the `sceneInventory` capability (Dart exploration mode) the evidence
// is the pre-tap evidence attached on the primary `down`, and its inventory
// is recorded as `scene_inventory` (deduped per session); otherwise it is
// the evidence attached on `up`.
void resolve_tap_evidence(Turn& turn, Transaction& tx,
                          const std::optional<TapEvidence>& up_evidence);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_TAP_EVIDENCE_H
