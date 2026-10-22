#include "tap_evidence.h"

#include <utility>

#include "engine_state.h"
#include "interaction_transaction.h"
#include "name_table.h"
#include "scene_inventory.h"
#include "turn.h"

namespace tugboat {
namespace engine {

namespace {

constexpr NamedValue<TapFailureReason> kFailureReasons[] = {
    {"no_target_at_point", TapFailureReason::kNoTargetAtPoint},
    {"no_scene_inventory", TapFailureReason::kNoSceneInventory},
    {"no_actionable_candidate", TapFailureReason::kNoActionableCandidate},
    {"outside_capture_boundary", TapFailureReason::kOutsideCaptureBoundary},
    {"stale_route_generation", TapFailureReason::kStaleRouteGeneration},
    {"opaque_platform_view", TapFailureReason::kOpaquePlatformView},
    {"system_ui", TapFailureReason::kSystemUi},
    {"resolution_error", TapFailureReason::kResolutionError},
};

bool decode_inventory(const ObjectReader& r, TapEvidence* out, Error* error) {
  const Value* json = nullptr;
  if (!r.opt_object("inventory", &json)) return false;
  if (json == nullptr) return true;
  // The inventory body is adapter evidence passed through as event data;
  // only its dedupe key is read.
  const ObjectReader inventory(*json, r.child("inventory"), error);
  TapInventory tap_inventory;
  if (!inventory.req_string("routeKey", &tap_inventory.route_key) ||
      !inventory.req_string("inventoryHash", &tap_inventory.inventory_hash)) {
    return false;
  }
  tap_inventory.json = *json;
  out->inventory = std::move(tap_inventory);
  return true;
}

}  // namespace

const char* tap_failure_reason_name(TapFailureReason reason) {
  return name_of(kFailureReasons, reason);
}

bool decode_tap_evidence(const Value& json, const std::string& path,
                         TapEvidence* out, Error* error) {
  const ObjectReader r(json, path, error);
  const Value* anchor = nullptr;
  std::optional<std::string> reason;
  if (!r.check_keys({"anchor", "failureReason", "inventory"}) ||
      !r.opt_object("anchor", &anchor) ||
      !decode_anchor(anchor, r.child("anchor"), &out->anchor, error) ||
      !r.opt_string("failureReason", &reason) ||
      !decode_inventory(r, out, error)) {
    return false;
  }
  if (reason) {
    out->failure_reason = parse_name(kFailureReasons, *reason);
    if (!out->failure_reason) {
      return r.reject("failureReason", "unknown failure reason");
    }
  }
  return true;
}

void resolve_tap_evidence(Turn& turn, Transaction& tx,
                          const std::optional<TapEvidence>& up_evidence) {
  if (!turn.state->config.capabilities.scene_inventory) {
    if (up_evidence) {
      tx.target_anchor = up_evidence->anchor;
      tx.failure_reason = up_evidence->failure_reason;
    }
    return;
  }
  // Dart `_resolveExplorationTapEvidence`. Dart also checks that the
  // evidence's route generation is the origin's (`stale_route_generation`);
  // both are stamped from the same `down` fact here, so it always holds.
  if (!tx.pre_tap_evidence) {
    tx.failure_reason = TapFailureReason::kNoTargetAtPoint;
    return;
  }
  const TapEvidence& evidence = *tx.pre_tap_evidence;
  tx.target_anchor = evidence.anchor;
  tx.failure_reason = evidence.failure_reason;
  if (evidence.inventory) {
    record_scene_inventory(turn, evidence.inventory->json);
  }
}

}  // namespace engine
}  // namespace tugboat
