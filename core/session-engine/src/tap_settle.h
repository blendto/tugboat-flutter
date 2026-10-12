// A tap after its pointer-up: the claim window and the tap-settle state
// machine.
//
// Claim window (Dart `_releaseInteractionClaim` and the reconciliation
// sweep): a released tap stays claimable as a navigation's cause until
// `claimWindowMs` after release, measured in fact time. The sweep timer fires
// `factGraceMs` late (design section 5) so a fact stamped inside the window
// that arrives late can still claim.
//
// Settle (Dart `_resolveTapSettle`): wait the settle delay, then the rest of
// the claim window (also `factGraceMs` late), then take a standalone
// `interaction` capture, and publish the tap with the temporal after-frame.
//
//   settle delay ──timer──► claim window ──timer or wake──► capturing ──►
//   published
//
// Phase 3d inserts the causal route barrier between the claim window and the
// capture: a tap a navigation claimed waits for that route's frame instead
// (`wake_tap_settle` is how the claim reaches the waiting settle).
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_TAP_SETTLE_H
#define TUGBOAT_SESSION_ENGINE_TAP_SETTLE_H

#include <string>

#include "capture_seam.h"
#include "interaction_transaction.h"
#include "interaction_turn.h"
#include "ordered_map.h"

namespace tugboat {
namespace engine {

// ---------------------------------------------------------------- claim window

constexpr char kSweepTimerId[] = "interaction.sweep";

// Releases a tap into the claim window and arms the sweep if it is idle.
void release_for_claims(InteractionTurn& turn, const TransactionPtr& tx);

// The sweep timer: expires released taps past their window (and the oldest
// beyond `maxReleased`), then re-arms while any remain.
void sweep_released(InteractionTurn& turn);

// Teardown: disarms the sweep and finalizes every released tap.
void clear_released(EngineState* state, Output* out);

// ---------------------------------------------------------------------- settle

// Timer ids are `interaction.settle.<interaction id>`.
constexpr char kSettleTimerPrefix[] = "interaction.settle.";

enum class SettlePhase { kSettleDelay, kClaimWindow, kCapturing };

struct TapSettle {
  TransactionPtr tx;
  SettlePhase phase = SettlePhase::kSettleDelay;
};

// Active settles by interaction id, in start order (Dart `_activeTapSettles`).
using TapSettles = OrderedMap<std::string, TapSettle>;

// Starts settling a released tap.
void start_tap_settle(InteractionTurn& turn, const TransactionPtr& tx);

// The settle timer of `interaction_id` fired.
void advance_tap_settle(InteractionTurn& turn,
                        const std::string& interaction_id);

// A navigation claimed the tap: a settle waiting out the claim window stops
// waiting (Dart `signalSuccessorClaimed`).
void wake_tap_settle(InteractionTurn& turn, const std::string& interaction_id);

// The settle's capture resolved: publish the tap.
void finish_tap_settle(InteractionTurn& turn,
                       const std::string& interaction_id,
                       const CaptureResolution& resolution);

// Teardown: cancels every settle. A tap still released is finalized by the
// released-transaction stage; one already settling is dropped, as in Dart.
void cancel_tap_settles(EngineState* state, Output* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_TAP_SETTLE_H
