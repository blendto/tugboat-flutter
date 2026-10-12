#include "gesture_completion.h"

#include <vector>

#include "after_frame.h"
#include "capture_requests.h"
#include "engine_state.h"
#include "interaction_claims.h"
#include "interaction_publish.h"

namespace tugboat {
namespace engine {

void complete_gesture(InteractionTurn& turn, const TransactionPtr& tx) {
  EngineState& state = *turn.state;
  tx->stage = TransactionStage::kSettling;
  state.interactions.gestures.put(tx->id(), tx);
  state.interactions.captures.issue(
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
      after_capture_frame(state.frames, *tx, *turn.session, resolution);
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
