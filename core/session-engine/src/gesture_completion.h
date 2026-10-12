// Swipe, pan, and zoom completion (Dart
// `_publishCompletedGestureAfterCapture`): a completed gesture asks for its
// own fresh `interaction` frame and publishes with the after-capture
// fallback chain. Teardown publishes waiting gestures without a frame and
// keeps their gesture. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_GESTURE_COMPLETION_H
#define TUGBOAT_SESSION_ENGINE_GESTURE_COMPLETION_H

#include <string>

#include "frame_ledger.h"
#include "interaction_transaction.h"
#include "interaction_turn.h"
#include "ordered_map.h"

namespace tugboat {
namespace engine {

// Gestures waiting for their after-capture, by interaction id, in order.
using GestureCaptures = OrderedMap<std::string, TransactionPtr>;

// Requests the gesture's after-capture.
void complete_gesture(InteractionTurn& turn, const TransactionPtr& tx);

// The after-capture of `interaction_id` resolved: publish the gesture.
void finish_gesture(InteractionTurn& turn, const std::string& interaction_id,
                    const CaptureResolution& resolution);

// Teardown (Dart `_finalizeActiveCompletedGestureCaptures`).
void finalize_gestures(EngineState* state, Output* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_GESTURE_COMPLETION_H
