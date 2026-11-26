// What every part of collector delivery works on while handling one message:
// the engine state, the message's fact time, and the output. Also the
// internal entry points the delivery files share. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DELIVERY_CONTEXT_H
#define TUGBOAT_SESSION_ENGINE_DELIVERY_CONTEXT_H

#include <cstddef>
#include <optional>
#include <string>

#include "clock.h"
#include "delivery_gaps.h"
#include "engine_state.h"
#include "output.h"
#include "transport.h"

namespace tugboat {
namespace engine {

// Delivery timer ids (`delivery.` prefix, routed by the module registry).
constexpr char kDeliveryTimerPrefix[] = "delivery.";
constexpr char kFlushTimer[] = "delivery.flush";            // every 3 s
constexpr char kBackgroundTimer[] = "delivery.background";  // 500 ms
constexpr char kIdentityTimer[] = "delivery.identity";      // 3 s debounce
constexpr char kEndDrainTimer[] = "delivery.endDrain";      // change C5
// `delivery.answer.<requestId>`: the answer deadline (change C15).
constexpr char kAnswerTimerPrefix[] = "delivery.answer.";

struct DeliveryContext {
  EngineState* state;
  At at;
  Output* out;

  DeliveryState& delivery() const { return state->delivery; }
  const CollectorConfig& config() const { return state->delivery.config; }
  // The session being delivered: the live one, or the last one while it
  // drains. Valid whenever delivery is not off.
  const Session& session() const { return *state->session; }
};

// flush_pass.cpp ---------------------------------------------------------

// A flush trigger: starts a pass, or marks a follow-up when one is running
// (change C2). Ignored while delivery is off.
void request_pass(DeliveryContext& ctx);
// A trigger that also drains the lifecycle lane (Dart
// `_drainLifecyclePosts`).
void request_lifecycle_drain(DeliveryContext& ctx);
// Applies the host's answer to the request in flight. Unknown and stale
// request ids are ignored (principle 4).
void apply_transport_result(DeliveryContext& ctx,
                            const TransportResult& result);
// Abandons the pass for a reset: the request in flight is orphaned, and the
// frames this pass took are released except the ones it is uploading.
void abandon_pass(DeliveryContext& ctx);

// delivery.cpp -----------------------------------------------------------

// Runs when a pass ends: lifecycle drain, follow-up, and session-end
// progress.
void on_pass_finished(DeliveryContext& ctx);

// delivery_lanes.cpp -----------------------------------------------------

// Queues a recorded event for the events lane (types the lifecycle lane
// carries are skipped).
void queue_event(DeliveryContext& ctx, const EventRecord& record);
// Records a gap diagnostic (change C6) when there is one to report.
void record_gap(DeliveryContext& ctx, std::optional<GapReport> report);
// Reports dropped events when `reportEventLaneGaps` is on.
void report_event_drop(DeliveryContext& ctx, EventDropReason reason,
                       size_t count, std::optional<int64_t> status);
// Drops delivery's reference to `uploads[begin, end)`.
void release_uploads(DeliveryContext& ctx, const FrameUploads& uploads,
                     size_t begin, size_t end);
// Frames evicted from the pending queue: released and reported.
void evicted_frames(DeliveryContext& ctx, const FrameUploads& evicted);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DELIVERY_CONTEXT_H
