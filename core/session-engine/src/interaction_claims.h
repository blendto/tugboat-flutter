// What navigation (phase 3d) uses from the interaction module, and what it
// supplies back. Phase 3c has no navigation messages, so nothing calls the
// claim API yet and the route stamp is empty.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_CLAIMS_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_CLAIMS_H

#include <string>

#include "clock.h"
#include "interaction_transaction.h"
#include "models.h"
#include "output.h"

namespace tugboat {
namespace engine {

struct EngineState;

// Dart `InteractionAttribution` for a successful claim.
enum class ClaimAttribution {
  kDirect,         // the pointer was still down, or no claim window is set
  kDelayedLikely,  // a released tap inside its claim window
};

enum class ClaimOutcome {
  kClaimed,
  kNone,               // nothing eligible
  kCompeting,          // more than one eligible transaction
  kNavigatorMismatch,  // the one eligible transaction began elsewhere
};

struct InteractionClaim {
  ClaimOutcome outcome = ClaimOutcome::kNone;
  std::string interaction_id;  // when claimed
  ClaimAttribution attribution = ClaimAttribution::kDirect;
};

// Dart `_tryClaimInteractionCause`, called when a navigation fact arrives,
// before the route epoch advances. Claims exactly one eligible transaction
// of the live, active session at fact time `at`, single use. `navigator_id`
// must match the transaction's origin navigator when both are known.
InteractionClaim claim_interaction_cause(EngineState* state, const At& at,
                                         const OptString& navigator_id);

// Wakes a claimed tap whose settle waits out its claim window, once the
// claiming route's barrier is registered (design section 8.1, step 5).
void wake_claimed_tap(EngineState* state, const std::string& interaction_id,
                      const At& at, Output* out);

// The visible route a new pointer-down records. Navigation supplies it in
// phase 3d; until then it is empty.
RouteStamp current_route_stamp(const EngineState& state);

// The capture context of a request made now (design section 8.2).
CaptureContext current_capture_context(const EngineState& state);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_CLAIMS_H
