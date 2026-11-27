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
  // Eviction keeps the frames an event points at (Dart `recordEvent`).
  for (const OptString* frame : {&record.event.before_frame,
                                 &record.event.after_frame}) {
    if (*frame) {
      d.frame_references.mark_referenced(**frame);
    }
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
  d.dropped_total += static_cast<int64_t>(evicted);
  report_event_drop(ctx, EventDropReason::kEvicted, evicted, std::nullopt);
}

void record_gap(DeliveryContext& ctx, std::optional<GapReport> report) {
  if (!report) {
    return;
  }
  EngineState* state = ctx.state;
  struct GapScope {
    explicit GapScope(DeliveryState& d) : d(d) { d.recording_gap = true; }
    ~GapScope() { d.recording_gap = false; }
    DeliveryState& d;
  } scope(ctx.delivery());
  // Dart's gap records: `collector-…-<UUIDv4>` ids on the semantic stream.
  Diagnostic gap;
  gap.data = std::move(report->data);
  gap.id = state->ids.next_id(report->id_prefix.c_str());
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
    finish_frame(ctx, uploads[i].frame_id);
  }
}

void finish_frame(DeliveryContext& ctx, const std::string& frame_id) {
  ctx.delivery().frame_references.finish(
      frame_id, bound(ctx.config().max_pending_frames));
}

FrameBounds frame_bounds(const DeliveryContext& ctx) {
  return FrameBounds{bound(ctx.config().max_pending_frames),
                     ctx.config().max_pending_frame_bytes};
}

void evicted_frames(DeliveryContext& ctx, const FrameEviction& evicted) {
  if (evicted.empty()) {
    return;
  }
  release_uploads(ctx, evicted.frames, 0, evicted.frames.size());
  const auto count = static_cast<int64_t>(evicted.frames.size());
  ctx.delivery().dropped_total += count;
  record_gap(ctx, ctx.delivery().frame_gaps.evicted(
                      count, static_cast<int64_t>(evicted.referenced)));
}

void delivery_event_recorded(const EventRecord& record, const At& at,
                             EngineState* state, Output* out) {
  DeliveryState& d = state->delivery;
  // Dart counts every event the hub accepts, `session_start` of a first
  // session included, which is recorded before delivery turns on.
  if (state->config.collector.enabled && !d.recording_gap) {
    ++d.accepted_total;
  }
  if (d.phase == DeliveryPhase::kOff) {
    return;
  }
  DeliveryContext ctx{state, at, out};
  queue_event(ctx, record);
  // The `batchSize`-th pending event triggers a pass, but delivery's own
  // reports never do (Dart `_recordDiagnostic` does not flush).
  if (!d.recording_gap && d.events.pending() >= bound(d.config.batch_size)) {
    request_pass(ctx);
  }
}

void delivery_frame_accepted(const Frame& frame, const std::string& handle,
                             EngineState* state, Output* out) {
  DeliveryState& d = state->delivery;
  if (d.phase != DeliveryPhase::kActive) {
    return;
  }
  DeliveryContext ctx{state, state->applying.at.value_or(At()), out};
  state->frame_retention.retain(frame.id, handle, FrameOwner::kDelivery);
  ++d.accepted_total;
  evicted_frames(ctx, d.frames.push(
                          PendingFrame{frame.number, frame.id, handle,
                                       frame_json(frame), frame.byte_length},
                          frame_bounds(ctx), d.frame_references));
  // While frames are retrying, the periodic timer paces them.
  if (!d.frames_need_retry) {
    request_pass(ctx);
  }
}

}  // namespace engine
}  // namespace tugboat
