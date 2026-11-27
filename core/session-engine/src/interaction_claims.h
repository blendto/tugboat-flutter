// What navigation uses from the interaction module (design section 8.1):
// claiming a navigation's cause, waking the claimed tap, and attaching the
// route frame to the cause. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_CLAIMS_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_CLAIMS_H

#include <string>

#include "clock.h"
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

// Dart `_attachCauseInteractionEvidence`: the route frame becomes the
// still-unpublished cause's after-frame (its own settlement may replace it).
void attach_route_frame(EngineState* state, const std::string& interaction_id,
                        const OptString& frame_id);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_CLAIMS_H
