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
#include <vector>

#include "collector_mapping.h"
#include "dart_time.h"
#include "delivery_bounds.h"
#include "delivery_context.h"
#include "delivery_keys.h"
#include "delivery_retry_after.h"

namespace tugboat {
namespace engine {

namespace {

void enter_lifecycle(DeliveryContext& ctx);
void begin_frames_step(DeliveryContext& ctx, bool between_events);
void enter_retry_batches(DeliveryContext& ctx);
void begin_event_drain(DeliveryContext& ctx);
void next_event_batch(DeliveryContext& ctx);
void send_frame_batch(DeliveryContext& ctx);
void send_isolated_frame(DeliveryContext& ctx);

// A pass at least this long records a `collector_flush` diagnostic (Dart's
// slow flush threshold).
constexpr int64_t kSlowFlushMs = 10000;

FlushCursor& cursor(DeliveryContext& ctx) { return ctx.delivery().pass; }

// What a request carries besides its body (`HttpSend`): the session id and
// the outbox delivery keys.
struct Keys {
  std::string session_id;
  std::vector<std::string> delivery_keys;
  bool is_session_end = false;
};

// Mints `http-N`, emits `http.send`, and arms its answer deadline; the
// pass waits for the result.
void send(DeliveryContext& ctx, HttpLane lane, const char* path,
          std::variant<JsonBody, MultipartBody> body, Keys keys,
          InFlight flight) {
  DeliveryState& d = ctx.delivery();
  flight.request_id = "http-" + std::to_string(d.next_request++);
  flight.sent_mono_us = ctx.at.mono_us;
  const int64_t timeout_ms = lane == HttpLane::kFrames
                                 ? d.config.frame_timeout_ms
                                 : d.config.json_timeout_ms;  // change C3
  ctx.out->effects.push_back(HttpSend{
      flight.request_id, lane, path, timeout_ms, std::move(body),
      std::move(keys.session_id), std::move(keys.delivery_keys),
      keys.is_session_end});
  // Change C15: without an answer by then, the request has timed out.
  ctx.state->timers.schedule(
      kAnswerTimerPrefix + flight.request_id,
      ctx.at.mono_us + (timeout_ms + d.config.answer_grace_ms) * 1000,
      ctx.out);
  cursor(ctx).in_flight = std::move(flight);
}

const char* step_name(PassStep step) {
  switch (step) {
    case PassStep::kSessions:
      return "sessions";
    case PassStep::kFrames:
      return "frames";
    case PassStep::kEventRetries:
      return "event_retries";
    case PassStep::kEvents:
      return "events";
  }
  return "none";
}

PassStep step_of(RequestKind kind) {
  switch (kind) {
    case RequestKind::kLifecycle:
      return PassStep::kSessions;
    case RequestKind::kFrameChunk:
    case RequestKind::kFrameSingle:
      return PassStep::kFrames;
    case RequestKind::kRetryBatch:
      return PassStep::kEventRetries;
    case RequestKind::kFreshBatch:
      return PassStep::kEvents;
  }
  return PassStep::kSessions;
}

// Marks `step` as run in this pass (Dart `_FlushTiming.step`).
void mark_step(DeliveryContext& ctx, PassStep step) {
  int64_t& us = cursor(ctx).step_us[static_cast<size_t>(step)];
  us = std::max<int64_t>(us, 0);
}

// Whether any lane still holds work the collector has not accepted (Dart
// `_awaitingRetry`).
bool awaiting_retry(const DeliveryState& d) {
  return d.frames_need_retry || d.events.has_retry() || !d.lifecycle.empty();
}

// Dart `_reportSlowFlush`.
void report_slow_flush(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  const FlushCursor& pass = d.pass;
  const int64_t elapsed_ms =
      std::max<int64_t>(ctx.at.mono_us - pass.started_mono_us, 0) / 1000;
  PassStep slowest = PassStep::kSessions;
  int64_t slowest_us = -1;
  for (size_t i = 0; i < pass.step_us.size(); ++i) {
    if (pass.step_us[i] > slowest_us) {
      slowest_us = pass.step_us[i];
      slowest = static_cast<PassStep>(i);
    }
  }
  record_gap(ctx, d.frame_gaps.flush_pass(
                      elapsed_ms >= kSlowFlushMs, awaiting_retry(d),
                      elapsed_ms, slowest_us < 0 ? "none" : step_name(slowest),
                      std::max<int64_t>(slowest_us, 0) / 1000));
}

void end_pass(DeliveryContext& ctx) {
  FlushCursor& pass = cursor(ctx);
  pass.running = false;
  pass.frames = FrameCursor();
  pass.frames_between_events = false;
  pass.events_remaining = 0;
  report_slow_flush(ctx);
  on_pass_finished(ctx);
}

// Dart `_noteRequestOutcome` and `_noteRequestError` for a `/v1/sessions` or
// `/v1/events/batch` post.
void note_request(DeliveryContext& ctx, const char* path,
                  const TransportResult& result) {
  FrameGaps& gaps = ctx.delivery().frame_gaps;
  if (result.outcome != TransportOutcome::kHttp) {
    record_gap(ctx, gaps.request_failed(
                        path, std::nullopt,
                        result.outcome == TransportOutcome::kTimeout
                            ? "timeout"
                            : "transport"));
  } else if (classify(result) == Verdict::kAccepted) {
    record_gap(ctx, gaps.request_accepted(path));
  } else {
    record_gap(ctx, gaps.request_failed(path, result.status, nullptr));
  }
}

bool has_collector_session_id(const DeliveryState& d) {
  return d.ids.session_id && !d.ids.session_id->empty();
}

// ------------------------------------------------------------- lifecycle

// `triggeredAt` of a lifecycle post: the fact's wall time, or, for a fact
// stamped only on the monotonic clock (`app.lifecycle` `detached` ending the
// session), the session start's wall time plus `atMs`, as for events.
int64_t triggered_at_us(const Session& session, const At& triggered,
                        int64_t at_ms) {
  if (triggered.wall_us) {
    return *triggered.wall_us;
  }
  const int64_t start_us = session.header().started_at_wall_us;
  int64_t derived_us = 0;
  return dart_add_ms_to_us(start_us, at_ms, &derived_us) ? derived_us
                                                         : start_us;
}

// The head's `/v1/sessions` body, built now from the current identity
// (section 7.1); only `triggeredAt` was fixed when it was queued.
LifecycleBody lifecycle_body(const DeliveryContext& ctx,
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
  body.triggered_at_us = triggered_at_us(session, entry.triggered, body.at_ms);
  const Identity& identity = ctx.state->identity;
  body.user_id = identity.user_id;
  body.traits = identity.traits ? &*identity.traits : nullptr;
  if (!identity.traits) {
    body.traits_id = d.ids.traits_id;
  }
  body.active_locale = entry.active_locale;
  return body;
}

void after_lifecycle(DeliveryContext& ctx) {
  // Events and frames never go out before the collector session id is known.
  if (has_collector_session_id(ctx.delivery())) {
    begin_frames_step(ctx, false);
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
    after_lifecycle(ctx);
    return;
  }
  const LifecycleEntry& head = d.lifecycle.head();
  const LifecycleBody body = lifecycle_body(ctx, head);
  Keys keys;
  keys.session_id = body.session_id;
  keys.delivery_keys.push_back(
      lifecycle_delivery_key(body.session_id, body.event_type,
                             dart_iso8601_utc(body.triggered_at_us)));
  keys.is_session_end = head.kind == LifecycleKind::kSessionEnd;
  InFlight flight;
  flight.kind = RequestKind::kLifecycle;
  send(ctx, HttpLane::kLifecycle, "/v1/sessions",
       JsonBody{encode_json(collector_lifecycle_json(*d.host, body))},
       std::move(keys), std::move(flight));
}

void on_lifecycle_result(DeliveryContext& ctx, const TransportResult& result) {
  DeliveryState& d = ctx.delivery();
  const Verdict verdict = classify(result);
  const LifecycleKind kind = d.lifecycle.head().kind;
  note_request(ctx, "/v1/sessions", result);
  if (verdict == Verdict::kAccepted) {
    apply_lifecycle_response(kind, result.body, ctx.session().id(), &d.ids);
    d.lifecycle.pop();
  } else if (verdict == Verdict::kDrop && kind != LifecycleKind::kSessionStart) {
    // A post the collector rejects would be rejected again, and at the head
    // it would hold every later post, `session_end` included. A
    // `session_start` stays until accepted: events and frames wait for the
    // collector session id it returns.
    d.lifecycle.pop();
  }
  after_lifecycle(ctx);
}

// ---------------------------------------------------------------- frames

// The frames step ends: on to the retry batches, or, between two event
// batches, to the next one.
void after_frames(DeliveryContext& ctx) {
  FlushCursor& pass = cursor(ctx);
  pass.frames = FrameCursor();
  if (pass.frames_between_events) {
    pass.frames_between_events = false;
    next_event_batch(ctx);
  } else {
    enter_retry_batches(ctx);
  }
}

// Dart `_flushFrames`: uploads one batch at a time, only the frames pending
// now. The rest stay pending under the bounds, so at most one batch is held
// beyond them, and frames captured meanwhile wait for the next pass.
void begin_frames_step(DeliveryContext& ctx, bool between_events) {
  DeliveryState& d = ctx.delivery();
  FlushCursor& pass = cursor(ctx);
  pass.frames_between_events = between_events;
  if (d.frames.empty() || lane_send_blocked(ctx, HttpLane::kFrames)) {
    after_frames(ctx);
    return;
  }
  mark_step(ctx, PassStep::kFrames);
  pass.frames = FrameCursor();
  pass.frames.remaining = d.frames.size();
  send_frame_batch(ctx);
}

void send_uploads(DeliveryContext& ctx, RequestKind kind, size_t begin,
                  size_t end) {
  const FrameUploads& uploads = cursor(ctx).frames.uploads;
  const std::string& session_id = *ctx.delivery().ids.session_id;
  InFlight flight;
  flight.kind = kind;
  Keys keys;
  keys.session_id = session_id;
  for (size_t i = begin; i < end; ++i) {
    flight.frame_ids.push_back(uploads[i].frame_id);
    keys.delivery_keys.push_back(
        frame_delivery_key(session_id, uploads[i].frame_no));
  }
  send(ctx, HttpLane::kFrames, "/v1/frames",
       frame_upload_body(session_id, uploads, begin, end), std::move(keys),
       std::move(flight));
}

// Every batch went out without a retry outcome.
void frames_flushed(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  d.frames_need_retry = false;
  record_gap(ctx, d.frame_gaps.flushed(cursor(ctx).frames.dropped_batch));
  after_frames(ctx);
}

// A retry outcome: `uploads[from..]` go back to the front of the queue and
// the frames step ends (section 7.6).
void requeue_from(DeliveryContext& ctx, size_t from) {
  DeliveryState& d = ctx.delivery();
  FrameUploads& uploads = cursor(ctx).frames.uploads;
  d.frames_need_retry = true;
  FrameUploads retry(std::make_move_iterator(uploads.begin() + from),
                     std::make_move_iterator(uploads.end()));
  cursor(ctx).frames.uploads.clear();
  evicted_frames(ctx, d.frames.requeue_front(std::move(retry),
                                             frame_bounds(ctx),
                                             d.frame_references));
  after_frames(ctx);
}

void send_frame_batch(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  FrameCursor& frames = cursor(ctx).frames;
  if (frames.remaining == 0 || d.frames.empty()) {
    frames_flushed(ctx);
    return;
  }
  frames.uploads = d.frames.take_batch(bound(ctx.config().frame_chunk));
  frames.remaining -= std::min(frames.remaining, frames.uploads.size());
  frames.chunk_begin = 0;
  frames.chunk_end = frames.uploads.size();
  send_uploads(ctx, RequestKind::kFrameChunk, 0, frames.chunk_end);
}

void next_chunk(DeliveryContext& ctx) {
  cursor(ctx).frames.uploads.clear();
  send_frame_batch(ctx);
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

Keys event_keys(const std::string& session_id, const EventBatch& batch) {
  Keys keys;
  keys.session_id = session_id;
  keys.delivery_keys.push_back(event_batch_delivery_key(session_id, batch));
  return keys;
}

// Dart `_sendEventBatch`'s bookkeeping: whether the post got an answer at
// all, and the request diagnostics.
void note_event_post(DeliveryContext& ctx, const TransportResult& result) {
  ctx.delivery().last_event_post_unanswered =
      result.outcome != TransportOutcome::kHttp;
  note_request(ctx, "/v1/events/batch", result);
}

// Moves `count` pending events into retry batches unsent (Dart
// `_parkPendingEvents`).
void park_pending_events(DeliveryContext& ctx, size_t count) {
  DeliveryState& d = ctx.delivery();
  const size_t evicted =
      d.events.park(count, bound(ctx.config().batch_size),
                    bound(ctx.config().max_pending_batches));
  d.dropped_total += static_cast<int64_t>(evicted);
  report_event_drop(ctx, EventDropReason::kEvicted, evicted, std::nullopt);
}

void enter_retry_batches(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  if (!d.events.has_retry()) {
    begin_event_drain(ctx);
    return;
  }
  if (lane_send_blocked(ctx, HttpLane::kEvents)) {
    end_pass(ctx);
    return;
  }
  mark_step(ctx, PassStep::kEventRetries);
  InFlight flight;
  flight.kind = RequestKind::kRetryBatch;
  std::string body = stamp_event_batch(&d.events.retry_head(),
                                       *d.ids.session_id, d.ids.traits_id);
  send(ctx, HttpLane::kEvents, "/v1/events/batch", JsonBody{std::move(body)},
       event_keys(*d.ids.session_id, d.events.retry_head()),
       std::move(flight));
}

void on_retry_batch_result(DeliveryContext& ctx,
                           const TransportResult& result) {
  DeliveryState& d = ctx.delivery();
  const Verdict verdict = classify(result);
  note_event_post(ctx, result);
  if (verdict == Verdict::kRetry) {
    // Head-of-line: the retry head stays; the pass moves on to fresh events.
    begin_event_drain(ctx);
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

// The pass reaches the fresh events (Dart `_flushFramesAndEvents`).
void begin_event_drain(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  if (d.events.has_retry() && d.last_event_post_unanswered) {
    // The retry head got no response at all, so the endpoint is down or
    // hung and a fresh batch would only wait out another timeout. A batch the
    // collector rejects gets a status back, so fresh events still go out
    // behind it; one that hangs the collector holds them in the retry queue
    // until it is evicted.
    park_pending_events(ctx, d.events.pending());
    end_pass(ctx);
    return;
  }
  cursor(ctx).events_remaining = d.events.pending();
  next_event_batch(ctx);
}

// Dart `_drainPendingEvents`: only the events queued when the drain began.
void next_event_batch(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  FlushCursor& pass = cursor(ctx);
  if (pass.events_remaining == 0 || d.events.pending() == 0 ||
      lane_send_blocked(ctx, HttpLane::kEvents)) {
    end_pass(ctx);
    return;
  }
  mark_step(ctx, PassStep::kEvents);
  InFlight flight;
  flight.kind = RequestKind::kFreshBatch;
  flight.batch = d.events.take(bound(ctx.config().batch_size));
  pass.events_remaining -= std::min(pass.events_remaining, flight.batch.size());
  std::string body =
      stamp_event_batch(&flight.batch, *d.ids.session_id, d.ids.traits_id);
  Keys keys = event_keys(*d.ids.session_id, flight.batch);
  send(ctx, HttpLane::kEvents, "/v1/events/batch", JsonBody{std::move(body)},
       std::move(keys), std::move(flight));
}

void on_fresh_batch_result(DeliveryContext& ctx, InFlight flight,
                           const TransportResult& result) {
  DeliveryState& d = ctx.delivery();
  FlushCursor& pass = cursor(ctx);
  const Verdict verdict = classify(result);
  const size_t count = flight.batch.size();
  note_event_post(ctx, result);
  if (verdict == Verdict::kRetry) {
    const size_t limit = bound(ctx.config().max_pending_batches);
    const size_t evicted = d.events.push_retry(std::move(flight.batch), limit);
    d.dropped_total += static_cast<int64_t>(evicted);
    report_event_drop(ctx, EventDropReason::kEvicted, evicted, std::nullopt);
    // The endpoint is failing or hung, so every further batch would wait out
    // its own timeout: park what is left of this pass's events instead.
    park_pending_events(ctx, pass.events_remaining);
    end_pass(ctx);
    return;
  }
  if (verdict == Verdict::kDrop) {
    report_event_drop(ctx, EventDropReason::kRejected, count,
                      result.status);
  }
  // Frames captured while that batch was in flight go before the next batch,
  // which may reference them. A failing frame lane waits for the next pass
  // instead of stalling every batch behind its timeout.
  if (d.frames_need_retry) {
    next_event_batch(ctx);
  } else {
    begin_frames_step(ctx, true);
  }
}

void begin_pass(DeliveryContext& ctx) {
  FlushCursor& pass = cursor(ctx);
  pass.running = true;
  pass.follow_up = false;
  pass.started_mono_us = ctx.at.mono_us;
  pass.step_us = {-1, -1, -1, -1};
  mark_step(ctx, PassStep::kSessions);
  enter_lifecycle(ctx);
}

}  // namespace

void request_pass(DeliveryContext& ctx) {
  FlushCursor& pass = cursor(ctx);
  if (ctx.delivery().phase == DeliveryPhase::kOff) {
    return;
  }
  if (pass.in_flight || pass.running) {
    // Change C2. Dart 0.11.1 also queues one follow-up pass for a `flush()`
    // during a pass, but not for the triggers that are not `flush()` calls.
    pass.follow_up = true;
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
    // Its session was replaced: the answer settles what it held.
    ctx.delivery().dropped_total += classify(result) == Verdict::kRetry
                                        ? flight.lost_on_retry
                                        : flight.lost_otherwise;
    for (const std::string& frame_id : flight.frame_ids) {
      ctx.state->frame_retention.release(frame_id, FrameOwner::kDelivery,
                                         ctx.out);
    }
    on_pass_finished(ctx);
    return;
  }
  {
    int64_t& us = pass.step_us[static_cast<size_t>(step_of(flight.kind))];
    us = std::max<int64_t>(us, 0) +
         std::max<int64_t>(ctx.at.mono_us - flight.sent_mono_us, 0);
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
    InFlight& flight = *pass.in_flight;
    uploading.insert(flight.frame_ids.begin(), flight.frame_ids.end());
    const auto batch = static_cast<int64_t>(pass.frames.uploads.size());
    // A request orphaned by an earlier reset keeps the counts taken then: the
    // pass cursor and queues belong to the newer session now.
    const bool first_reset = !flight.orphaned;
    flight.orphaned = true;
    switch (first_reset ? flight.kind : RequestKind::kLifecycle) {
      case RequestKind::kLifecycle:
        break;
      case RequestKind::kFreshBatch:
        flight.orphan_pending = flight.lost_on_retry =
            static_cast<int64_t>(flight.batch.size());
        break;
      case RequestKind::kRetryBatch:  // already out of the retry queue
        flight.orphan_pending = flight.lost_on_retry =
            static_cast<int64_t>(ctx.delivery().events.retry_head_size());
        break;
      case RequestKind::kFrameChunk:
        flight.orphan_pending = flight.lost_on_retry = batch;
        break;
      case RequestKind::kFrameSingle: {
        const auto unsent = batch - static_cast<int64_t>(pass.frames.isolate_index);
        flight.orphan_pending = batch;
        flight.lost_on_retry = unsent;
        flight.lost_otherwise = unsent - 1;
        break;
      }
    }
  }
  for (const PendingFrame& frame : pass.frames.uploads) {
    if (uploading.count(frame.frame_id) == 0) {
      ctx.state->frame_retention.release(frame.frame_id, FrameOwner::kDelivery,
                                         ctx.out);
    }
  }
  pass.running = false;
  pass.frames = FrameCursor();
  pass.frames_between_events = false;
  pass.events_remaining = 0;
  pass.follow_up = false;
  pass.drain_head.reset();
}

}  // namespace engine
}  // namespace tugboat
