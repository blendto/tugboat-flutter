// The flush pass (docs/stateful-engine.md sections 7.3, 7.4, and 7.6): Dart's
// `_flushOnce` as an explicit cursor (flush_cursor.h). Each `enter_*`
// transition either sends the next request, which parks the pass until its
// `transport.result` (the request's kind says which step answers it), or
// moves on to the next step. Each result handler
// applies what the response means and then makes the next transition.
#include <algorithm>
#include <set>
#include <string>
#include <utility>
#include <variant>

#include "collector_mapping.h"
#include "delivery_bounds.h"
#include "delivery_context.h"
#include "delivery_retry_after.h"

namespace tugboat {
namespace engine {

namespace {

void enter_lifecycle(DeliveryContext& ctx);
void enter_frames(DeliveryContext& ctx);
void enter_retry_batches(DeliveryContext& ctx);
void enter_fresh_events(DeliveryContext& ctx);
void send_frame_chunk(DeliveryContext& ctx);
void send_isolated_frame(DeliveryContext& ctx);

FlushCursor& cursor(DeliveryContext& ctx) { return ctx.delivery().pass; }

// Mints `http-N`, emits `http.send`, and arms its answer deadline; the
// pass waits for the result.
void send(DeliveryContext& ctx, HttpLane lane, const char* path,
          std::variant<JsonBody, MultipartBody> body, InFlight flight) {
  DeliveryState& d = ctx.delivery();
  flight.request_id = "http-" + std::to_string(d.next_request++);
  const int64_t timeout_ms = lane == HttpLane::kFrames
                                 ? d.config.frame_timeout_ms
                                 : d.config.json_timeout_ms;  // change C3
  ctx.out->effects.push_back(
      HttpSend{flight.request_id, lane, path, timeout_ms, std::move(body)});
  // Change C15: without an answer by then, the request has timed out.
  ctx.state->timers.schedule(
      kAnswerTimerPrefix + flight.request_id,
      ctx.at.mono_us + (timeout_ms + d.config.answer_grace_ms) * 1000,
      ctx.out);
  cursor(ctx).in_flight = std::move(flight);
}

void end_pass(DeliveryContext& ctx) {
  FlushCursor& pass = cursor(ctx);
  pass.running = false;
  pass.frames = FrameCursor();
  on_pass_finished(ctx);
}

bool has_collector_session_id(const DeliveryState& d) {
  return d.ids.session_id && !d.ids.session_id->empty();
}

// ------------------------------------------------------------- lifecycle

// The head's `/v1/sessions` body, built now from the current identity
// (section 7.1); only `triggeredAt` was fixed when it was queued.
std::string lifecycle_body(const DeliveryContext& ctx,
                           const LifecycleEntry& entry) {
  const DeliveryState& d = ctx.delivery();
  const Session& session = ctx.session();
  LifecycleBody body;
  body.event_type = lifecycle_kind_name(entry.kind);
  body.session_id = entry.kind == LifecycleKind::kSessionStart
                        ? session.id()
                        : d.ids.session_id.value_or(session.id());
  body.at_ms =
      elapsed_ms(session.header().start_mono_us, entry.triggered.mono_us);
  body.triggered_at_us = entry.triggered.wall_us.value_or(0);
  const Identity& identity = ctx.state->identity;
  body.user_id = identity.user_id;
  body.traits = identity.traits ? &*identity.traits : nullptr;
  if (!identity.traits) {
    body.traits_id = d.ids.traits_id;
  }
  body.active_locale = entry.active_locale;
  return encode_json(collector_lifecycle_json(*d.host, body));
}

void after_lifecycle(DeliveryContext& ctx) {
  // Events and frames never go out before the collector session id is known.
  if (has_collector_session_id(ctx.delivery())) {
    enter_frames(ctx);
  } else {
    end_pass(ctx);
  }
}

void enter_lifecycle(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  if (d.lifecycle.empty()) {
    after_lifecycle(ctx);
    return;
  }
  if (lane_send_blocked(ctx, HttpLane::kLifecycle)) {
    end_pass(ctx);
    return;
  }
  InFlight flight;
  flight.kind = RequestKind::kLifecycle;
  send(ctx, HttpLane::kLifecycle, "/v1/sessions",
       JsonBody{lifecycle_body(ctx, d.lifecycle.head())}, std::move(flight));
}

void on_lifecycle_result(DeliveryContext& ctx, const TransportResult& result) {
  DeliveryState& d = ctx.delivery();
  if (classify(result) == Verdict::kAccepted) {
    apply_lifecycle_response(d.lifecycle.head().kind, result.body,
                             ctx.session().id(), &d.ids);
    d.lifecycle.pop();
  }
  after_lifecycle(ctx);
}

// ---------------------------------------------------------------- frames

void enter_frames(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  if (d.frames.empty()) {
    enter_retry_batches(ctx);
    return;
  }
  if (lane_send_blocked(ctx, HttpLane::kFrames)) {
    enter_retry_batches(ctx);
    return;
  }
  cursor(ctx).frames = FrameCursor();
  cursor(ctx).frames.uploads = d.frames.take_sorted();
  send_frame_chunk(ctx);
}

void send_uploads(DeliveryContext& ctx, RequestKind kind, size_t begin,
                  size_t end) {
  const FrameUploads& uploads = cursor(ctx).frames.uploads;
  InFlight flight;
  flight.kind = kind;
  for (size_t i = begin; i < end; ++i) {
    flight.frame_ids.push_back(uploads[i].frame_id);
  }
  send(ctx, HttpLane::kFrames, "/v1/frames",
       frame_upload_body(*ctx.delivery().ids.session_id, uploads, begin, end),
       std::move(flight));
}

// Every chunk went out without a retry outcome.
void frames_flushed(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  d.frames_need_retry = false;
  record_gap(ctx, d.frame_gaps.flushed(cursor(ctx).frames.dropped_batch));
  cursor(ctx).frames = FrameCursor();
  enter_retry_batches(ctx);
}

// A retry outcome: `uploads[from..]` go back to the front of the queue and
// the frames stage ends (section 7.6).
void requeue_from(DeliveryContext& ctx, size_t from) {
  DeliveryState& d = ctx.delivery();
  FrameUploads& uploads = cursor(ctx).frames.uploads;
  d.frames_need_retry = true;
  FrameUploads retry(std::make_move_iterator(uploads.begin() + from),
                     std::make_move_iterator(uploads.end()));
  cursor(ctx).frames = FrameCursor();
  const size_t limit = bound(ctx.config().max_pending_frames);
  evicted_frames(ctx, d.frames.requeue_front(std::move(retry), limit));
  enter_retry_batches(ctx);
}

void send_frame_chunk(DeliveryContext& ctx) {
  FrameCursor& frames = cursor(ctx).frames;
  if (frames.chunk_begin >= frames.uploads.size()) {
    frames_flushed(ctx);
    return;
  }
  const size_t chunk = bound(ctx.config().frame_chunk);
  frames.chunk_end =
      std::min(frames.chunk_begin + chunk, frames.uploads.size());
  send_uploads(ctx, RequestKind::kFrameChunk, frames.chunk_begin,
               frames.chunk_end);
}

void next_chunk(DeliveryContext& ctx) {
  FrameCursor& frames = cursor(ctx).frames;
  frames.chunk_begin = frames.chunk_end;
  send_frame_chunk(ctx);
}

void on_frame_chunk_result(DeliveryContext& ctx,
                           const TransportResult& result) {
  DeliveryState& d = ctx.delivery();
  FrameCursor& frames = cursor(ctx).frames;
  const auto count =
      static_cast<int64_t>(frames.chunk_end - frames.chunk_begin);
  const Verdict verdict = classify(result);
  if (verdict != Verdict::kAccepted) {
    record_gap(ctx, d.frame_gaps.failed(result.status, count));
  }
  if (verdict == Verdict::kRetry) {
    requeue_from(ctx, frames.chunk_begin);
    return;
  }
  if (verdict == Verdict::kDrop && result.status == 400 && count > 1) {
    // One invalid capture must not discard its valid neighbours.
    frames.isolate_index = frames.chunk_begin;
    frames.isolate_dropped = false;
    send_isolated_frame(ctx);
    return;
  }
  frames.dropped_batch = frames.dropped_batch || verdict == Verdict::kDrop;
  release_uploads(ctx, frames.uploads, frames.chunk_begin, frames.chunk_end);
  next_chunk(ctx);
}

void send_isolated_frame(DeliveryContext& ctx) {
  FrameCursor& frames = cursor(ctx).frames;
  if (frames.isolate_index >= frames.chunk_end) {
    frames.dropped_batch = frames.dropped_batch || frames.isolate_dropped;
    next_chunk(ctx);
    return;
  }
  send_uploads(ctx, RequestKind::kFrameSingle, frames.isolate_index,
               frames.isolate_index + 1);
}

void on_isolated_frame_result(DeliveryContext& ctx,
                              const TransportResult& result) {
  DeliveryState& d = ctx.delivery();
  FrameCursor& frames = cursor(ctx).frames;
  const Verdict verdict = classify(result);
  if (verdict == Verdict::kRetry) {
    record_gap(ctx, d.frame_gaps.failed(result.status, 1));
    requeue_from(ctx, frames.isolate_index);
    return;
  }
  if (verdict == Verdict::kDrop) {
    frames.isolate_dropped = true;
    record_gap(ctx, d.frame_gaps.failed(result.status, 1));
  }
  release_uploads(ctx, frames.uploads, frames.isolate_index,
                  frames.isolate_index + 1);
  ++frames.isolate_index;
  send_isolated_frame(ctx);
}

// ---------------------------------------------------------------- events

void enter_retry_batches(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  if (!d.events.has_retry()) {
    enter_fresh_events(ctx);
    return;
  }
  if (lane_send_blocked(ctx, HttpLane::kEvents)) {
    end_pass(ctx);
    return;
  }
  InFlight flight;
  flight.kind = RequestKind::kRetryBatch;
  send(ctx, HttpLane::kEvents, "/v1/events/batch",
       JsonBody{stamp_event_batch(&d.events.retry_head(), *d.ids.session_id,
                                  d.ids.traits_id)},
       std::move(flight));
}

void on_retry_batch_result(DeliveryContext& ctx,
                           const TransportResult& result) {
  DeliveryState& d = ctx.delivery();
  const Verdict verdict = classify(result);
  if (verdict == Verdict::kRetry) {
    // Head-of-line: the retry head stays; fresh events still go out.
    enter_fresh_events(ctx);
    return;
  }
  const size_t count = d.events.retry_head().size();
  d.events.pop_retry();
  if (verdict == Verdict::kDrop) {
    report_event_drop(ctx, EventDropReason::kRejected, count,
                      result.status);
  }
  enter_retry_batches(ctx);
}

void enter_fresh_events(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  if (d.events.pending() == 0) {
    end_pass(ctx);
    return;
  }
  if (lane_send_blocked(ctx, HttpLane::kEvents)) {
    end_pass(ctx);
    return;
  }
  InFlight flight;
  flight.kind = RequestKind::kFreshBatch;
  flight.batch = d.events.take(bound(ctx.config().batch_size));
  std::string body =
      stamp_event_batch(&flight.batch, *d.ids.session_id, d.ids.traits_id);
  send(ctx, HttpLane::kEvents, "/v1/events/batch", JsonBody{std::move(body)},
       std::move(flight));
}

void on_fresh_batch_result(DeliveryContext& ctx, InFlight flight,
                           const TransportResult& result) {
  DeliveryState& d = ctx.delivery();
  const Verdict verdict = classify(result);
  const size_t count = flight.batch.size();
  if (verdict == Verdict::kRetry) {
    const size_t limit = bound(ctx.config().max_pending_batches);
    const size_t evicted = d.events.push_retry(std::move(flight.batch), limit);
    report_event_drop(ctx, EventDropReason::kEvicted, evicted, std::nullopt);
  } else if (verdict == Verdict::kDrop) {
    report_event_drop(ctx, EventDropReason::kRejected, count,
                      result.status);
  }
  enter_fresh_events(ctx);
}

void begin_pass(DeliveryContext& ctx) {
  cursor(ctx).running = true;
  cursor(ctx).follow_up = false;
  enter_lifecycle(ctx);
}

}  // namespace

void request_pass(DeliveryContext& ctx) {
  FlushCursor& pass = cursor(ctx);
  if (ctx.delivery().phase == DeliveryPhase::kOff) {
    return;
  }
  if (pass.in_flight || pass.running) {
    pass.follow_up = true;  // change C2: Dart drops this trigger
    return;
  }
  begin_pass(ctx);
}

void request_lifecycle_drain(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  if (!d.lifecycle.empty()) {
    d.pass.drain_head = d.lifecycle.head().seq;
  }
  request_pass(ctx);
}

void apply_transport_result(DeliveryContext& ctx,
                            const TransportResult& result) {
  FlushCursor& pass = cursor(ctx);
  if (!pass.in_flight || pass.in_flight->request_id != result.request_id) {
    return;
  }
  InFlight flight = std::move(*pass.in_flight);
  pass.in_flight.reset();
  ctx.state->timers.cancel(kAnswerTimerPrefix + flight.request_id, ctx.out);
  if (flight.orphaned) {
    for (const std::string& frame_id : flight.frame_ids) {
      ctx.state->frame_retention.release(frame_id, FrameOwner::kDelivery,
                                         ctx.out);
    }
    on_pass_finished(ctx);
    return;
  }
  maybe_arm_lane_retry_after(ctx, http_lane_for_request(flight.kind), result);
  switch (flight.kind) {
    case RequestKind::kLifecycle:
      on_lifecycle_result(ctx, result);
      break;
    case RequestKind::kFrameChunk:
      on_frame_chunk_result(ctx, result);
      break;
    case RequestKind::kFrameSingle:
      on_isolated_frame_result(ctx, result);
      break;
    case RequestKind::kRetryBatch:
      on_retry_batch_result(ctx, result);
      break;
    case RequestKind::kFreshBatch:
      on_fresh_batch_result(ctx, std::move(flight), result);
      break;
  }
}

void abandon_pass(DeliveryContext& ctx) {
  FlushCursor& pass = cursor(ctx);
  std::set<std::string> uploading;
  if (pass.in_flight) {
    pass.in_flight->orphaned = true;
    uploading.insert(pass.in_flight->frame_ids.begin(),
                     pass.in_flight->frame_ids.end());
  }
  for (const PendingFrame& frame : pass.frames.uploads) {
    if (uploading.count(frame.frame_id) == 0) {
      ctx.state->frame_retention.release(frame.frame_id, FrameOwner::kDelivery,
                                         ctx.out);
    }
  }
  pass.running = false;
  pass.frames = FrameCursor();
  pass.follow_up = false;
  pass.drain_head.reset();
}

}  // namespace engine
}  // namespace tugboat
