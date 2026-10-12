#include "claim_window.h"

#include <optional>

#include "engine_state.h"
#include "interaction_publish.h"

namespace tugboat {
namespace engine {

namespace {

// Dart `_ensureReconciliationSweepScheduled`: one sweep timer, armed for the
// earliest deadline plus the fact grace.
void ensure_sweep(InteractionTurn& turn) {
  EngineState& state = *turn.state;
  if (state.timers.armed(kSweepTimerId)) return;
  const std::optional<int64_t> earliest =
      state.interactions.registry.earliest_claim_deadline();
  if (!earliest) return;
  const int64_t grace_ms = state.config.interaction.fact_grace_ms;
  state.timers.schedule(kSweepTimerId, turn.mono_at_ms(*earliest + grace_ms),
                        turn.out);
}

}  // namespace

void release_for_claims(InteractionTurn& turn, const TransactionPtr& tx) {
  EngineState& state = *turn.state;
  if (!tx->released_at_ms) tx->released_at_ms = turn.now_ms();
  state.interactions.registry.release(tx);
  // A zero window (Dart's microtask-only rollback mode) closes at release.
  tx->claim_deadline_ms =
      *tx->released_at_ms + state.config.interaction.claim_window_ms;
  ensure_sweep(turn);
}

void sweep_released(InteractionTurn& turn) {
  EngineState& state = *turn.state;
  const InteractionConfig& config = state.config.interaction;
  state.interactions.registry.sweep(turn.now_ms(), config.fact_grace_ms,
                                    config.max_released);
  if (state.interactions.registry.has_released()) ensure_sweep(turn);
}

void clear_released(EngineState* state, Output* out) {
  state->timers.cancel(kSweepTimerId, out);
  Session* session = state->live_session();
  for (const TransactionPtr& tx :
       state->interactions.registry.take_all_released()) {
    if (session != nullptr) finalize_abandoned(state, *session, *tx, out);
  }
}

}  // namespace engine
}  // namespace tugboat
