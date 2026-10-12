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

#include <cstdint>
#include <set>
#include <string>

#include "capture_seam.h"
#include "interaction_transaction.h"
#include "models.h"
#include "ordered_map.h"
#include "output.h"
#include "route_work.h"
#include "session.h"
#include "turn.h"

namespace tugboat {
namespace engine {

struct EngineState;

// Records `tx`'s `interaction` event in `session` once; later calls do
// nothing. The transaction becomes published and leaves the id index.
void publish_interaction(EngineState* state, Session& session, Transaction& tx,
                         Output* out);

// Ends an unpublished transaction early (cancel of a released tap,
// abandonment, teardown): drops its scroll completion and causal route
// state, and publishes it. A tap becomes `cancelled`; swipe, scroll, pan,
// and zoom keep their gesture.
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

// Dart `_temporalAfterFrameAfterCapture`, the after-capture fallback chain
// of a completed swipe, pan, zoom, or scroll:
//   1. the fresh frame its own capture accepted, when it is temporal;
//   2. else the frame of the active route capture, following the routes
//      that supersede it, when temporal (waiting on each barrier);
//   3. else the session's latest frame, when temporal.
struct AfterCaptureWalk {
  std::set<int64_t> visited;  // route epochs already waited on
};

// Whether a walk step decided the frame or waits on a route barrier
// (resumed through `continue_after_capture_walk`).
enum class WalkStep { kDone, kWaiting };

WalkStep begin_after_capture_walk(Turn& turn, const Transaction& tx,
                                  const CaptureResolution& resolution,
                                  const BarrierWaiter& waiter,
                                  AfterCaptureWalk* walk, OptString* frame);
WalkStep continue_after_capture_walk(Turn& turn, const Transaction& tx,
                                     const RouteWork& barrier,
                                     const BarrierWaiter& waiter,
                                     AfterCaptureWalk* walk,
                                     OptString* frame);

// ---------------------------------------------------------- gesture completion

// A swipe, pan, or zoom between its pointer-up and its publication:
//
//   capturing ──resolved──► walking (route barriers) ──► publishing (queue)
//        └──────────── fresh temporal frame ───────────────┘
struct GestureCapture {
  enum class Stage { kCapturing, kWalking, kPublishing };
  TransactionPtr tx;
  Stage stage = Stage::kCapturing;
  AfterCaptureWalk walk;
};

// Completing gestures by interaction id, in order.
using GestureCaptures = OrderedMap<std::string, GestureCapture>;

// Requests the gesture's after-capture.
void complete_gesture(Turn& turn, const TransactionPtr& tx);

// The after-capture of `interaction_id` resolved.
void finish_gesture(Turn& turn, const std::string& interaction_id,
                    const CaptureResolution& resolution);

// A route barrier the gesture's walk waits on is done.
void gesture_route_barrier_done(Turn& turn, const std::string& interaction_id,
                                const RouteWork& barrier);

// The publication queue reached the gesture: publish it.
void publish_completed_gesture(Turn& turn, const std::string& interaction_id);

// Teardown (Dart `_finalizeActiveCompletedGestureCaptures`).
void finalize_gestures(EngineState* state, Output* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_PUBLISH_H
