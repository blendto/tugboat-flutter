#include "pointer_interactions.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "tap_settle.h"
#include "engine_state.h"
#include "interaction_publish.h"
#include "interaction_claims.h"
#include "interaction_payload.h"
#include "scroll_interactions.h"
#include "tap_evidence.h"

namespace tugboat {
namespace engine {

namespace {

void abandon_pending(EngineState* state, Session* session, int64_t pointer,
                     Output* out) {
  const TransactionPtr tx = state->interactions.registry.take_pending(pointer);
  if (tx != nullptr && session != nullptr) {
    finalize_abandoned(state, *session, *tx, out);
  }
}

void pointer_down(InteractionTurn& turn, const PointerDownSignal& signal) {
  EngineState& state = *turn.state;
  InteractionState& interactions = state.interactions;
  // A new gesture makes a waiting scroll-end frame stale.
  const std::vector<std::string> stale =
      cancel_scroll_end_delays(&state, turn.out);
  if (const TransactionPtr previous =
          interactions.registry.take_released(signal.pointer)) {
    finalize_abandoned(&state, *turn.session, *previous, turn.out);
  }
  abandon_pending(&state, turn.session, signal.pointer, turn.out);
  const bool primary = !interactions.registry.has_pending();
  const FrameProvenance* before = state.captures.latest(turn.session->id());

  InteractionOrigin origin;
  origin.interaction_id = state.ids.next("event");
  origin.route = current_route_stamp(state);
  origin.coordinate = sample_coordinate(signal.position, before);
  if (before != nullptr) origin.before_frame = before->frame_id;
  origin.at_ms = turn.now_ms();
  origin.start_position = signal.position;
  origin.session_id = turn.session->id();
  origin.locale = state.locale;
  const TransactionPtr tx =
      std::make_shared<Transaction>(std::move(origin), signal.pointer);
  interactions.registry.add_pending(tx);
  // Exploration mode keeps the primary pointer's pre-tap evidence.
  if (state.config.capabilities.scene_inventory && primary) {
    tx->pre_tap_evidence = signal.tap;
  }
  for (const std::string& start_id : stale) {
    publish_resolved_scroll(&state, *turn.session, start_id, turn.out);
  }
}

void pointer_up(InteractionTurn& turn, const PointerUpSignal& signal) {
  EngineState& state = *turn.state;
  const TransactionPtr tx =
      state.interactions.registry.take_pending(signal.pointer);
  if (tx == nullptr) return;
  tx->released_at_ms = turn.now_ms();
  tx->released_frame_sequence = state.captures.sequence();
  const bool scroll_linked = !tx->scroll_start_ids.empty();
  if (is_pan_or_zoom(tx->gesture) && (is_zoom(tx->gesture) || !scroll_linked)) {
    tx->end_position = signal.position;
    complete_gesture(turn, tx);
    return;
  }
  // Change C12: a tap that owns a scroll start completes as that scroll.
  if (skips_tap_settlement(tx->gesture) || scroll_linked) {
    tx->end_position = signal.position;
    if (scroll_linked) {
      tx->gesture = Gesture::kScroll;
      attach_scroll_interaction(&state, *turn.session,
                                tx->scroll_start_ids.front(), tx, turn.out);
    } else {
      tx->gesture = Gesture::kSwipe;
      complete_gesture(turn, tx);
    }
    return;
  }
  resolve_tap_evidence(turn, *tx, signal.tap);
  release_for_claims(turn, tx);
  start_tap_settle(turn, tx);
}

void pointer_cancel(InteractionTurn& turn, const PointerCancelSignal& signal) {
  EngineState& state = *turn.state;
  InteractionRegistry& registry = state.interactions.registry;
  // Even a pending swipe is cancelled; abandonment would keep it.
  if (const TransactionPtr tx = registry.take_pending(signal.pointer)) {
    discard_scroll_completion(&state, *tx, turn.out);
    tx->gesture = Gesture::kCancelled;
    publish_interaction(&state, *turn.session, *tx, turn.out);
  }
  if (const TransactionPtr tx = registry.take_released(signal.pointer)) {
    finalize_abandoned(&state, *turn.session, *tx, turn.out);
  }
}

struct SignalVisitor {
  InteractionTurn& turn;

  void operator()(const PointerDownSignal& signal) const {
    pointer_down(turn, signal);
  }
  void operator()(const MarkSwipeSignal& signal) const {
    if (const TransactionPtr tx =
            turn.state->interactions.registry.pending_at(signal.pointer)) {
      tx->mark_swipe();
    }
  }
  void operator()(const MarkClusterSignal& signal) const {
    if (const TransactionPtr tx =
            turn.state->interactions.registry.pending_at(signal.pointer)) {
      tx->mark_cluster(signal.gesture, signal.scale, signal.pointer_count);
    }
  }
  void operator()(const SuppressSignal& signal) const {
    if (const TransactionPtr tx =
            turn.state->interactions.registry.take_pending(signal.pointer)) {
      absorb_interaction(turn.state, *tx, turn.out);
    }
  }
  void operator()(const PointerUpSignal& signal) const {
    pointer_up(turn, signal);
  }
  void operator()(const PointerCancelSignal& signal) const {
    pointer_cancel(turn, signal);
  }
};

}  // namespace

void apply_pointer_signals(InteractionTurn& turn,
                           const PointerSignals& signals) {
  if (turn.state->lifecycle != LifecycleState::kActive) return;
  for (const PointerSignal& signal : signals) {
    std::visit(SignalVisitor{turn}, signal);
  }
}

void abandon_pending_pointers(EngineState* state, Output* out) {
  Session* session = state->live_session();
  for (int64_t pointer : state->interactions.registry.pending_pointers()) {
    abandon_pending(state, session, pointer, out);
  }
}

}  // namespace engine
}  // namespace tugboat
