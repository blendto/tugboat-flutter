#include "interaction_publish.h"

#include <optional>
#include <utility>
#include <vector>

#include "coordination.h"
#include "engine_state.h"
#include "interaction_payload.h"
#include "navigation_view.h"
#include "recorder.h"
#include "route_barrier.h"
#include "scroll_interactions.h"

namespace tugboat {
namespace engine {

namespace {

OptString temporal_latest(const Turn& turn, const Transaction& tx) {
  const FrameProvenance* latest =
      turn.state->captures.latest(turn.session->id());
  return temporal_after_frame(
      turn.state->captures, tx, *turn.session,
      latest == nullptr ? std::nullopt : OptString(latest->frame_id));
}

// Waits on `route` unless the walk already did; else ends with the latest
// frame.
WalkStep walk_to(Turn& turn, const Transaction& tx, const RouteWorkPtr& route,
                 const BarrierWaiter& waiter, AfterCaptureWalk* walk,
                 OptString* frame) {
  if (route != nullptr && walk->visited.insert(route->epoch).second) {
    await_route_barrier(turn.state, route, waiter);
    return WalkStep::kWaiting;
  }
  *frame = temporal_latest(turn, tx);
  return WalkStep::kDone;
}

void publish_gesture(Turn& turn, GestureCapture& gesture,
                     const OptString& frame) {
  gesture.tx->after_frame = frame;
  gesture.stage = GestureCapture::Stage::kPublishing;
  enqueue_publication(turn.state, GesturePublication{gesture.tx->id()});
}

}  // namespace

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
  clear_causal_route_state(state, tx.id());
  discard_scroll_completion(state, tx, out);
  if (!skips_tap_settlement(tx.gesture)) tx.gesture = Gesture::kCancelled;
  publish_interaction(state, session, tx, out);
}

void absorb_interaction(EngineState* state, Transaction& tx, Output* out) {
  if (tx.terminal()) return;
  discard_scroll_completion(state, tx, out);
  clear_causal_route_state(state, tx.id());
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

WalkStep begin_after_capture_walk(Turn& turn, const Transaction& tx,
                                  const CaptureResolution& resolution,
                                  const BarrierWaiter& waiter,
                                  AfterCaptureWalk* walk, OptString* frame) {
  const OptString captured = temporal_after_frame(
      turn.state->captures, tx, *turn.session, resolution.frame_id);
  if (resolution.outcome == CaptureOutcome::kFreshAccepted && captured) {
    *frame = captured;
    return WalkStep::kDone;
  }
  return walk_to(turn, tx, latest_route_capture(*turn.state), waiter, walk,
                 frame);
}

WalkStep continue_after_capture_walk(Turn& turn, const Transaction& tx,
                                     const RouteWork& barrier,
                                     const BarrierWaiter& waiter,
                                     AfterCaptureWalk* walk,
                                     OptString* frame) {
  const OptString route_frame = temporal_after_frame(
      turn.state->captures, tx, *turn.session, barrier.result->frame_id);
  if (route_frame) {
    *frame = route_frame;
    return WalkStep::kDone;
  }
  return walk_to(turn, tx, barrier.superseded_by, waiter, walk, frame);
}

void complete_gesture(Turn& turn, const TransactionPtr& tx) {
  EngineState& state = *turn.state;
  tx->stage = TransactionStage::kSettling;
  GestureCapture gesture;
  gesture.tx = tx;
  state.interactions.gestures.put(tx->id(), std::move(gesture));
  state.captures.request(turn, {CaptureOwner::Kind::kGesture, tx->id()},
                         interaction_capture(tx->id()));
}

void finish_gesture(Turn& turn, const std::string& interaction_id,
                    const CaptureResolution& resolution) {
  GestureCapture* gesture =
      turn.state->interactions.gestures.find(interaction_id);
  if (gesture == nullptr ||
      gesture->stage != GestureCapture::Stage::kCapturing) {
    return;
  }
  OptString frame;
  const BarrierWaiter waiter{BarrierWaiter::Kind::kGestureWalk,
                             interaction_id, std::nullopt};
  gesture->stage = GestureCapture::Stage::kWalking;
  if (begin_after_capture_walk(turn, *gesture->tx, resolution, waiter,
                               &gesture->walk, &frame) == WalkStep::kDone) {
    publish_gesture(turn, *gesture, frame);
  }
}

void gesture_route_barrier_done(Turn& turn, const std::string& interaction_id,
                                const RouteWork& barrier) {
  GestureCapture* gesture =
      turn.state->interactions.gestures.find(interaction_id);
  if (gesture == nullptr ||
      gesture->stage != GestureCapture::Stage::kWalking) {
    return;
  }
  OptString frame;
  const BarrierWaiter waiter{BarrierWaiter::Kind::kGestureWalk,
                             interaction_id, std::nullopt};
  if (continue_after_capture_walk(turn, *gesture->tx, barrier, waiter,
                                  &gesture->walk, &frame) == WalkStep::kDone) {
    publish_gesture(turn, *gesture, frame);
  }
}

void publish_completed_gesture(Turn& turn, const std::string& interaction_id) {
  GestureCaptures& gestures = turn.state->interactions.gestures;
  const GestureCapture* gesture = gestures.find(interaction_id);
  if (gesture == nullptr ||
      gesture->stage != GestureCapture::Stage::kPublishing) {
    return;
  }
  const TransactionPtr tx = gesture->tx;
  gestures.erase(interaction_id);
  publish_interaction(turn.state, *turn.session, *tx, turn.out);
}

void finalize_gestures(EngineState* state, Output* out) {
  GestureCaptures& gestures = state->interactions.gestures;
  std::vector<TransactionPtr> waiting;
  for (const auto& entry : gestures.entries()) {
    waiting.push_back(entry.second.tx);
  }
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
