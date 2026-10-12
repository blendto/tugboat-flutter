// Publishing a transaction's one `interaction` event: the publication
// itself, the terminal paths that publish early (Dart
// `_publishCanonicalInteraction`, `_finalizeAbandonedTransaction`,
// `suppressPendingPointer`), the temporal after-frame rules
// (`_temporalAfterFrame`, `_temporalAfterFrameAfterCapture`), and the
// swipe, pan, and zoom completion that waits for its own fresh capture
// (`_publishCompletedGestureAfterCapture`). An after-frame is only an
// observation made after the interaction; it claims nothing about cause.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_PUBLISH_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_PUBLISH_H

#include <string>

#include "capture_seam.h"
#include "interaction_transaction.h"
#include "interaction_turn.h"
#include "models.h"
#include "ordered_map.h"
#include "output.h"
#include "session.h"

namespace tugboat {
namespace engine {

struct EngineState;

// Records `tx`'s `interaction` event in `session` once; later calls do
// nothing. The transaction becomes published and leaves the id index.
void publish_interaction(EngineState* state, Session& session, Transaction& tx,
                         Output* out);

// Ends an unpublished transaction early (cancel of a released tap,
// abandonment, teardown): drops its scroll completion and publishes it. A
// tap becomes `cancelled`; swipe, scroll, pan, and zoom keep their gesture.
void finalize_abandoned(EngineState* state, Session& session, Transaction& tx,
                        Output* out);

// A secondary pointer joined another pointer's cluster gesture: it drops its
// scroll completion and leaves without an event (Dart
// `suppressPendingPointer`).
void absorb_interaction(EngineState* state, Transaction& tx, Output* out);

// ---------------------------------------------------------------- after-frames

// `frame_id` when it belongs to `session`, completed no earlier than the
// release (or the pointer-down, before release), and is newer than the frame
// sequence at release.
OptString temporal_after_frame(const CaptureSeam& captures,
                               const Transaction& tx, const Session& session,
                               const OptString& frame_id);

// The after-capture fallback chain of a completed gesture: the fresh frame
// its own capture accepted when it is temporal, else the session's latest
// frame when it is. (Phase 3d adds route barrier frames between the two.)
OptString after_capture_frame(const CaptureSeam& captures,
                              const Transaction& tx,
                              const Session& session,
                              const CaptureResolution& resolution);

// ---------------------------------------------------------- gesture completion

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

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_PUBLISH_H
