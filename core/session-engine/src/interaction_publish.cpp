#include "interaction_publish.h"

#include <utility>

#include "engine_state.h"
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

}  // namespace engine
}  // namespace tugboat
