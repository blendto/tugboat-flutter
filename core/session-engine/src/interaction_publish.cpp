#include "interaction_publish.h"

#include <optional>
#include <utility>
#include <vector>

#include "engine_state.h"
#include "interaction_claims.h"
#include "interaction_payload.h"
#include "recorder.h"
#include "scroll_interactions.h"

namespace tugboat {
namespace engine {

void publish_interaction(EngineState* state, Session& session, Transaction& tx,
                         Output* out) {
  if (tx.terminal()) return;
  tx.stage = TransactionStage::kPublished;
  Event event = interaction_event(tx);
  tx.discard_pre_tap_evidence();
  record_event(state, session, std::move(event), true, out);
  state->interactions.registry.forget(tx.id());
}

void finalize_abandoned(EngineState* state, Session& session, Transaction& tx,
                        Output* out) {
  if (tx.terminal()) return;
  discard_scroll_completion(state, tx, out);
  if (!skips_tap_settlement(tx.gesture)) tx.gesture = Gesture::kCancelled;
  publish_interaction(state, session, tx, out);
}

void absorb_interaction(EngineState* state, Transaction& tx, Output* out) {
  if (tx.terminal()) return;
  discard_scroll_completion(state, tx, out);
  tx.stage = TransactionStage::kAbsorbed;
  state->interactions.registry.forget(tx.id());
}

OptString temporal_after_frame(const CaptureSeam& captures,
                               const Transaction& tx, const Session& session,
                               const OptString& frame_id) {
  ObservationBoundary boundary;
  boundary.session_id = session.id();
  boundary.at_ms = tx.released_at_ms.value_or(tx.origin.at_ms);
  boundary.after_sequence = tx.released_frame_sequence;
  return captures.observed_after(frame_id, boundary);
}

OptString after_capture_frame(const CaptureSeam& captures, const Transaction& tx,
                              const Session& session,
                              const CaptureResolution& resolution) {
  const OptString captured =
      temporal_after_frame(captures, tx, session, resolution.frame_id);
  if (resolution.outcome == CaptureOutcome::kFreshAccepted && captured) {
    return captured;
  }
  const FrameProvenance* latest = captures.latest(session.id());
  return temporal_after_frame(
      captures, tx, session,
      latest == nullptr ? std::nullopt : OptString(latest->frame_id));
}

void complete_gesture(InteractionTurn& turn, const TransactionPtr& tx) {
  EngineState& state = *turn.state;
  tx->stage = TransactionStage::kSettling;
  state.interactions.gestures.put(tx->id(), tx);
  state.captures.issue(
      {CaptureOwner::Kind::kGesture, tx->id()},
      interaction_capture(turn.at.mono_us, current_capture_context(state)),
      &state.ids, turn.out);
}

void finish_gesture(InteractionTurn& turn, const std::string& interaction_id,
                    const CaptureResolution& resolution) {
  EngineState& state = *turn.state;
  GestureCaptures& gestures = state.interactions.gestures;
  const TransactionPtr* found = gestures.find(interaction_id);
  if (found == nullptr) return;
  const TransactionPtr tx = *found;
  gestures.erase(interaction_id);
  tx->after_frame =
      after_capture_frame(state.captures, *tx, *turn.session, resolution);
  publish_interaction(&state, *turn.session, *tx, turn.out);
}

void finalize_gestures(EngineState* state, Output* out) {
  GestureCaptures& gestures = state->interactions.gestures;
  std::vector<TransactionPtr> waiting;
  for (const auto& entry : gestures.entries()) waiting.push_back(entry.second);
  gestures.clear();
  Session* session = state->live_session();
  if (session == nullptr) return;
  for (const TransactionPtr& tx : waiting) {
    tx->after_frame.reset();
    finalize_abandoned(state, *session, *tx, out);
  }
}

}  // namespace engine
}  // namespace tugboat
