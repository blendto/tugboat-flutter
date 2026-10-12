#include "tap_settle.h"

#include <optional>

#include "engine_state.h"
#include "interaction_claims.h"
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

std::string timer_id(const std::string& interaction_id) {
  return kSettleTimerPrefix + interaction_id;
}

void request_capture(InteractionTurn& turn, TapSettle& settle) {
  EngineState& state = *turn.state;
  settle.phase = SettlePhase::kCapturing;
  state.captures.issue(
      {CaptureOwner::Kind::kTapSettle, settle.tx->id()},
      interaction_capture(turn.at.mono_us, current_capture_context(state)),
      &state.ids, turn.out);
}

// Dart `_waitForTapClaimWindow`: wait out the rest of the claim window,
// unless the tap is already claimed.
void enter_claim_window(InteractionTurn& turn, TapSettle& settle) {
  EngineState& state = *turn.state;
  const InteractionConfig& config = state.config.interaction;
  const Transaction& tx = *settle.tx;
  if (config.claim_window_ms > 0 && !tx.claimed && tx.claim_deadline_ms) {
    const int64_t wait_until_ms = *tx.claim_deadline_ms + config.fact_grace_ms;
    if (turn.now_ms() < wait_until_ms) {
      settle.phase = SettlePhase::kClaimWindow;
      state.timers.schedule(timer_id(tx.id()), turn.mono_at_ms(wait_until_ms),
                            turn.out);
      return;
    }
  }
  request_capture(turn, settle);
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

void start_tap_settle(InteractionTurn& turn, const TransactionPtr& tx) {
  EngineState& state = *turn.state;
  TapSettles& settles = state.interactions.settles;
  settles.put(tx->id(), TapSettle{tx, SettlePhase::kSettleDelay});
  TapSettle& settle = *settles.find(tx->id());
  const int64_t delay_ms = state.config.interaction.settle_delay_ms;
  if (delay_ms > 0) {
    state.timers.schedule(timer_id(tx->id()),
                          turn.at.mono_us + delay_ms * 1000, turn.out);
    return;
  }
  enter_claim_window(turn, settle);
}

void advance_tap_settle(InteractionTurn& turn,
                        const std::string& interaction_id) {
  TapSettle* settle = turn.state->interactions.settles.find(interaction_id);
  if (settle == nullptr) return;
  switch (settle->phase) {
    case SettlePhase::kSettleDelay:
      enter_claim_window(turn, *settle);
      break;
    case SettlePhase::kClaimWindow:
      request_capture(turn, *settle);
      break;
    case SettlePhase::kCapturing:
      break;
  }
}

void wake_tap_settle(InteractionTurn& turn, const std::string& interaction_id) {
  TapSettle* settle = turn.state->interactions.settles.find(interaction_id);
  if (settle == nullptr || settle->phase != SettlePhase::kClaimWindow) return;
  turn.state->timers.cancel(timer_id(interaction_id), turn.out);
  request_capture(turn, *settle);
}

void finish_tap_settle(InteractionTurn& turn,
                       const std::string& interaction_id,
                       const CaptureResolution& resolution) {
  EngineState& state = *turn.state;
  TapSettles& settles = state.interactions.settles;
  const TapSettle* settle = settles.find(interaction_id);
  if (settle == nullptr || settle->phase != SettlePhase::kCapturing) return;
  const TransactionPtr tx = settle->tx;
  settles.erase(interaction_id);
  // Dart `_standaloneTapSameRouteObservation`. The frame matches the tap's
  // origin when the capture seam knows it (phase 3d also compares route
  // epochs).
  const bool captured =
      resolution.frame_id &&
      state.captures.find(*resolution.frame_id) != nullptr;
  if (captured) {
    tx->after_frame = resolution.frame_id;
  } else {
    const FrameProvenance* latest = state.captures.latest(turn.session->id());
    tx->after_frame = temporal_after_frame(
        state.captures, *tx, *turn.session,
        latest == nullptr ? std::nullopt : OptString(latest->frame_id));
  }
  tx->gesture = Gesture::kTap;
  publish_interaction(&state, *turn.session, *tx, turn.out);
}

void cancel_tap_settles(EngineState* state, Output* out) {
  TapSettles& settles = state->interactions.settles;
  for (const std::string& id : settles.keys()) {
    state->timers.cancel(timer_id(id), out);
  }
  settles.clear();
}

}  // namespace engine
}  // namespace tugboat
