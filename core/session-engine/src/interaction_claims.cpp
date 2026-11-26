#include "interaction_claims.h"

#include <vector>

#include "engine_state.h"
#include "tap_settle.h"
#include "turn.h"

namespace tugboat {
namespace engine {

namespace {

// Dart `_claimingIsAvailable`: not in the background, not after the end.
Session* claiming_session(EngineState* state) {
  if (state->lifecycle != LifecycleState::kActive) return nullptr;
  return state->live_session();
}

}  // namespace

InteractionClaim claim_interaction_cause(EngineState* state, const At& at,
                                         const OptString& navigator_id) {
  InteractionClaim claim;
  Session* session = claiming_session(state);
  if (session == nullptr) return claim;
  const InteractionRegistry& registry = state->interactions.registry;
  const std::vector<TransactionPtr> eligible =
      registry.claimable(session->at_ms(at.mono_us), session->id());
  if (eligible.size() != 1) {
    if (eligible.size() > 1) claim.outcome = ClaimOutcome::kCompeting;
    return claim;
  }
  Transaction& tx = *eligible.front();
  const OptString& origin_navigator = tx.origin.route.navigator_id;
  if (navigator_id && origin_navigator && *origin_navigator != *navigator_id) {
    claim.outcome = ClaimOutcome::kNavigatorMismatch;
    return claim;
  }
  tx.claimed = true;
  const bool window_active = state->config.interaction.claim_window_ms > 0;
  claim.outcome = ClaimOutcome::kClaimed;
  claim.interaction_id = tx.id();
  claim.attribution = tx.stage == TransactionStage::kPending || !window_active
                          ? ClaimAttribution::kDirect
                          : ClaimAttribution::kDelayedLikely;
  return claim;
}

void wake_claimed_tap(EngineState* state, const std::string& interaction_id,
                      const At& at, Output* out) {
  Session* session = state->live_session();
  if (session == nullptr) return;
  Turn turn{state, session, at, out};
  wake_tap_settle(turn, interaction_id);
}

void attach_route_frame(EngineState* state, const std::string& interaction_id,
                        const OptString& frame_id) {
  if (!frame_id) return;
  const TransactionPtr tx = state->interactions.registry.find(interaction_id);
  if (tx != nullptr) tx->after_frame = frame_id;
}

}  // namespace engine
}  // namespace tugboat
