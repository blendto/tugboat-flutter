// Queueing into the collector lanes (docs/stateful-engine.md sections 7.2,
// 7.5, 7.6, and 7.7): events mapped at record time, frames with their
// delivery reference, gap diagnostics, and frame release.
#include <utility>

#include "collector_mapping.h"
#include "dart_time.h"
#include "delivery.h"
#include "delivery_bounds.h"
#include "delivery_context.h"
#include "recorder.h"

namespace tugboat {
namespace engine {

namespace {

// Dart's collector sink skips the types the lifecycle lane posts.
bool is_lifecycle_type(const std::string& type) {
  return type == "session_start" || type == "session_end";
}

}  // namespace

void queue_event(DeliveryContext& ctx, const EventRecord& record) {
  DeliveryState& d = ctx.delivery();
  if (d.phase == DeliveryPhase::kOff || is_lifecycle_type(record.event.type)) {
    return;
  }
  int64_t triggered_at_us = 0;
  if (!dart_add_ms_to_us(ctx.session().header().started_at_wall_us,
                         record.event.at_ms, &triggered_at_us)) {
    return;  // Dart's mapping throws (RangeError); the sink drops the event.
  }
  // `userId` is stamped now (record time); `sessionId` and `traitsId` when
  // the batch is sent (section 7.2).
  const CollectorStamp stamp{std::nullopt, record.user_id, std::nullopt};
  const size_t evicted = d.events.push(
      collector_event_json(record.event, *d.host, stamp, triggered_at_us),
      bound(ctx.config().max_pending_events));
  report_event_drop(ctx, EventDropReason::kEvicted, evicted, std::nullopt);
}

void record_gap(DeliveryContext& ctx, std::optional<GapReport> report) {
  if (!report) {
    return;
  }
  EngineState* state = ctx.state;
  // Dart's gap records: `collector-…` ids on the semantic stream.
  Diagnostic gap;
  gap.data = std::move(report->data);
  gap.id = std::move(report->id);
  gap.stream = EventStream::kSemantic;
  if (state->live_session() != nullptr) {
    record_diagnostic(state, ctx.at, ctx.out, std::move(gap));
    return;
  }
  // The session ended and its delivery is draining: the gap is still a
  // record and still goes to the collector, but the closed in-memory session
  // takes no more events. Change C1: fact time, as for every event.
  const EventRecord record{
      enrich(diagnostic_event(state, ctx.session(), ctx.at.mono_us,
                              std::move(gap)),
             ctx.session(), state->locale, true),
      state->identity.user_id};
  ctx.out->records.push_back(record);
  queue_event(ctx, record);
}

void report_event_drop(DeliveryContext& ctx, EventDropReason reason,
                       size_t count, std::optional<int64_t> status) {
  DeliveryState& d = ctx.delivery();
  if (!d.config.report_event_lane_gaps || count == 0) {
    return;  // change C6: event-lane gaps are opt-in
  }
  record_gap(ctx, d.event_gaps.dropped(reason, static_cast<int64_t>(count),
                                       status));
}

void release_uploads(DeliveryContext& ctx, const FrameUploads& uploads,
                     size_t begin, size_t end) {
  for (size_t i = begin; i < end; ++i) {
    ctx.state->frame_retention.release(uploads[i].frame_id,
                                       FrameOwner::kDelivery, ctx.out);
  }
}

void evicted_frames(DeliveryContext& ctx, const FrameUploads& evicted) {
  if (evicted.empty()) {
    return;
  }
  release_uploads(ctx, evicted, 0, evicted.size());
  record_gap(ctx, ctx.delivery().frame_gaps.evicted(
                      static_cast<int64_t>(evicted.size())));
}

void delivery_event_recorded(const EventRecord& record, const At& at,
                             EngineState* state, Output* out) {
  DeliveryState& d = state->delivery;
  if (d.phase == DeliveryPhase::kOff) {
    return;
  }
  DeliveryContext ctx{state, at, out};
  queue_event(ctx, record);
  // The `batchSize`-th pending event triggers a pass.
  if (d.events.pending() >= bound(d.config.batch_size)) {
    request_pass(ctx);
  }
}

void delivery_frame_accepted(const Frame& frame, const std::string& handle,
                             EngineState* state, Output* out) {
  DeliveryState& d = state->delivery;
  int64_t frame_no = 0;
  // Engine frame ids always end in their number (`frame-N`).
  if (d.phase != DeliveryPhase::kActive ||
      !frame_number(frame.id, &frame_no)) {
    return;
  }
  DeliveryContext ctx{state, state->applying.at.value_or(At()), out};
  state->frame_retention.retain(frame.id, handle, FrameOwner::kDelivery);
  evicted_frames(ctx, d.frames.push(PendingFrame{frame_no, frame.id, handle,
                                                 frame_json(frame)},
                                    bound(ctx.config().max_pending_frames)));
  // While frames are retrying, the periodic timer paces them.
  if (!d.frames_need_retry) {
    request_pass(ctx);
  }
}

}  // namespace engine
}  // namespace tugboat
