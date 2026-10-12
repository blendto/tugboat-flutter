// The claim window after a tap's pointer-up (Dart `_releaseInteractionClaim`
// and the reconciliation sweep): a released tap stays claimable as a
// navigation's cause until `claimWindowMs` after release, measured in fact
// time. The sweep timer fires `factGraceMs` late (design section 5) so a fact
// stamped inside the window that arrives late can still claim.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CLAIM_WINDOW_H
#define TUGBOAT_SESSION_ENGINE_CLAIM_WINDOW_H

#include "interaction_transaction.h"
#include "interaction_turn.h"

namespace tugboat {
namespace engine {

constexpr char kSweepTimerId[] = "interaction.sweep";

// Releases a tap into the claim window and arms the sweep if it is idle.
void release_for_claims(InteractionTurn& turn, const TransactionPtr& tx);

// The sweep timer: expires released taps past their window (and the oldest
// beyond `maxReleased`), then re-arms while any remain.
void sweep_released(InteractionTurn& turn);

// Teardown: disarms the sweep and finalizes every released tap.
void clear_released(EngineState* state, Output* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CLAIM_WINDOW_H
