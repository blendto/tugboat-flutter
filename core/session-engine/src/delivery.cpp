// Collector delivery phases and triggers (docs/stateful-engine.md sections
// 7.1, 7.3, and 7.7): session start and reset, the periodic, background,
// identity, and end-drain timers, identity changes, and the session end
// sequence (change C5). The pass itself is in flush_pass.cpp.
#include <string>
#include <utility>

#include "delivery.h"
#include "delivery_context.h"

namespace tugboat {
namespace engine {

namespace {

int64_t after_ms(const At& at, int64_t ms) { return at.mono_us + ms * 1000; }

bool lanes_empty(const DeliveryState& d) {
  return d.events.empty() && d.frames.empty() &&
         d.pass.frames.uploads.empty();
}

// Nothing left to deliver for the ended session.
bool delivery_complete(const DeliveryState& d) {
  return lanes_empty(d) && d.lifecycle.empty() && !d.held_session_end;
}

void cancel_timers(DeliveryContext& ctx) {
  for (const char* timer :
       {kFlushTimer, kBackgroundTimer, kIdentityTimer, kEndDrainTimer}) {
    ctx.state->timers.cancel(timer, ctx.out);
  }
}

// Delivery work the collector has not confirmed (section 7.7): `undelivered`
// work is queued (never sent, or waiting to be retried); `inFlight` is the
// request whose answer is still pending.
struct Unconfirmed {
  int64_t lifecycle = 0;
  int64_t events = 0;
  int64_t frames = 0;

  bool empty() const { return lifecycle == 0 && events == 0 && frames == 0; }
};

int64_t count(size_t n) { return static_cast<int64_t>(n); }

// Reports unconfirmed work once, as a `collector_delivery` health record,
// when delivery discards it (a new session, or `engine.dispose`). A request
// orphaned by an earlier reset was reported then.
void report_unconfirmed(DeliveryContext& ctx) {
  const DeliveryState& d = ctx.delivery();
  Unconfirmed undelivered;
  undelivered.lifecycle =
      count(d.lifecycle.size()) + (d.held_session_end ? 1 : 0);
  undelivered.events = count(d.events.event_count());
  undelivered.frames = count(d.frames.size() + d.pass.frames.uploads.size());
  Unconfirmed in_flight;
  if (d.pass.in_flight && !d.pass.in_flight->orphaned) {
    const InFlight& flight = *d.pass.in_flight;
    switch (flight.kind) {
      case RequestKind::kLifecycle:  // still the lane's head
        in_flight.lifecycle = 1;
        undelivered.lifecycle -= 1;
        break;
      case RequestKind::kFrameChunk:
      case RequestKind::kFrameSingle:  // still among the pass's uploads
        in_flight.frames = count(flight.frame_ids.size());
        undelivered.frames -= in_flight.frames;
        break;
      case RequestKind::kRetryBatch:  // still the retry head
        in_flight.events = count(d.events.retry_head_size());
        undelivered.events -= in_flight.events;
        break;
      case RequestKind::kFreshBatch:
        in_flight.events = count(flight.batch.size());
        break;
    }
  }
  if (undelivered.empty() && in_flight.empty()) {
    return;
  }
  ctx.out->records.push_back(
      HealthRecord{"collector_delivery",
                   {{"undeliveredLifecycle", undelivered.lifecycle},
                    {"undeliveredEvents", undelivered.events},
                    {"undeliveredFrames", undelivered.frames},
                    {"inFlightLifecycle", in_flight.lifecycle},
                    {"inFlightEvents", in_flight.events},
                    {"inFlightFrames", in_flight.frames}}});
}

// Dart `startSession`'s reset. The traits bag and traits id survive.
void reset(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  if (d.phase != DeliveryPhase::kOff) {
    report_unconfirmed(ctx);
  }
  abandon_pass(ctx);
  for (const PendingFrame& frame : d.frames.take_all()) {
    ctx.state->frame_retention.release(frame.frame_id, FrameOwner::kDelivery,
                                       ctx.out);
  }
  cancel_timers(ctx);
  d.ids.session_id.reset();
  d.lifecycle.clear();
  d.debounce.reset();
  d.held_session_end.reset();
  d.events.clear();
  d.frames_need_retry = false;
  d.frame_gaps = FrameGaps();
  d.event_gaps = EventGaps();
  d.phase = DeliveryPhase::kOff;
}

// Change C5: the drain is over (lanes empty or timed out), so `session_end`
// joins the lifecycle lane. Delivery keeps retrying from here on.
void finish_drain(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  ctx.state->timers.cancel(kEndDrainTimer, ctx.out);
  d.lifecycle.push(LifecycleKind::kSessionEnd, *d.held_session_end,
                   std::nullopt);
  d.held_session_end.reset();
  d.phase = DeliveryPhase::kEnded;
  request_lifecycle_drain(ctx);
}

// Dart `_enqueueCoalescedIdentityUpdate`.
void queue_identity_post(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  if (const std::optional<IdentityPost> post = d.debounce.take()) {
    d.lifecycle.push(post->kind, post->triggered, std::nullopt);
  }
}

// Dart `setUserId` / `setTraits` after the stored value changed.
void identity_changed(DeliveryContext& ctx, bool user) {
  DeliveryState& d = ctx.delivery();
  // No session yet; a pending `session_start` folds the change into its
  // body, which is built when it is sent.
  if (d.phase == DeliveryPhase::kOff || d.lifecycle.has_session_start()) {
    return;
  }
  if (user) {
    d.debounce.mark_user_changed(ctx.at);
  } else {
    d.debounce.mark_traits_changed(ctx.at);
  }
  ctx.state->timers.schedule(kIdentityTimer,
                             after_ms(ctx.at, d.config.identity_debounce_ms),
                             ctx.out);
}

// The periodic flush timer (Dart `Timer.periodic`): re-armed on its own
// schedule before the pass, so a pass that completes delivery can stop it.
void periodic_flush(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  const int64_t interval_us = d.config.flush_interval_ms * 1000;
  do {
    d.flush_deadline_us += interval_us;
  } while (d.flush_deadline_us <= ctx.at.mono_us);
  ctx.state->timers.schedule(kFlushTimer, d.flush_deadline_us, ctx.out);
  request_pass(ctx);
}

}  // namespace

void on_pass_finished(DeliveryContext& ctx) {
  DeliveryState& d = ctx.delivery();
  FlushCursor& pass = d.pass;
  if (pass.drain_head) {
    if (!d.lifecycle.empty() && d.lifecycle.head().seq != *pass.drain_head) {
      pass.drain_head = d.lifecycle.head().seq;
      request_pass(ctx);
      return;
    }
    pass.drain_head.reset();
  }
  if (pass.follow_up) {
    request_pass(ctx);
    return;
  }
  if (d.phase == DeliveryPhase::kDraining && lanes_empty(d)) {
    finish_drain(ctx);
  } else if (d.phase == DeliveryPhase::kEnded && delivery_complete(d)) {
    ctx.state->timers.cancel(kFlushTimer, ctx.out);
  }
}

void delivery_session_started(const At& at, EngineState* state, Output* out) {
  DeliveryContext ctx{state, at, out};
  DeliveryState& d = state->delivery;
  reset(ctx);
  if (!state->config.collector.enabled) {
    return;
  }
  const Session& session = ctx.session();
  d.phase = DeliveryPhase::kActive;
  d.host = state->config.host;
  d.config = state->config.collector;
  d.flush_deadline_us = after_ms(at, d.config.flush_interval_ms);
  state->timers.schedule(kFlushTimer, d.flush_deadline_us, out);
  d.lifecycle.push(
      LifecycleKind::kSessionStart,
      At{session.header().start_mono_us, session.header().started_at_wall_us},
      session.locale());
  // A request of the previous session still in flight holds the single
  // slot; the pass then follows it (Dart `_kickFlush`).
  request_pass(ctx);
}

void delivery_backgrounded(const At& at, EngineState* state, Output* out) {
  const DeliveryState& d = state->delivery;
  if (d.phase == DeliveryPhase::kActive) {
    state->timers.schedule(
        kBackgroundTimer, after_ms(at, d.config.background_flush_delay_ms),
        out);
  }
}

void delivery_foregrounded(const At& /*at*/, EngineState* state,
                           Output* out) {
  state->timers.cancel(kBackgroundTimer, out);
}

void delivery_session_ending(const At& at, EngineState* state, Output* out) {
  DeliveryState& d = state->delivery;
  if (d.phase != DeliveryPhase::kActive) {
    return;
  }
  DeliveryContext ctx{state, at, out};
  state->timers.cancel(kBackgroundTimer, out);
  // Dart `endSession` first posts a debounced identity change.
  state->timers.cancel(kIdentityTimer, out);
  queue_identity_post(ctx);
  // Change C5: `session_end` waits for frames and events to drain, for at
  // most `endDrainTimeoutMs`. Its `triggeredAt` is the end fact's time.
  d.held_session_end = at;
  d.phase = DeliveryPhase::kDraining;
  if (lanes_empty(d) && !d.pass.in_flight) {
    finish_drain(ctx);  // nothing to drain
    return;
  }
  state->timers.schedule(kEndDrainTimer,
                         after_ms(at, d.config.end_drain_timeout_ms), out);
  request_lifecycle_drain(ctx);
}

void delivery_timer_fired(const std::string& timer_id, const At& at,
                          EngineState* state, Output* out) {
  DeliveryContext ctx{state, at, out};
  DeliveryState& d = state->delivery;
  const std::string answer_prefix = kAnswerTimerPrefix;
  if (timer_id.compare(0, answer_prefix.size(), answer_prefix) == 0) {
    // Change C15: no answer by the deadline is a timeout (retry rules
    // apply); a later answer is then unknown and ignored.
    TransportResult overdue;
    overdue.request_id = timer_id.substr(answer_prefix.size());
    overdue.outcome = TransportOutcome::kTimeout;
    apply_transport_result(ctx, overdue);
    return;
  }
  if (d.phase == DeliveryPhase::kOff) {
    return;
  }
  if (timer_id == kFlushTimer) {
    periodic_flush(ctx);
  } else if (timer_id == kBackgroundTimer) {
    request_pass(ctx);
  } else if (timer_id == kIdentityTimer) {
    queue_identity_post(ctx);
    request_lifecycle_drain(ctx);
  } else if (timer_id == kEndDrainTimer &&
             d.phase == DeliveryPhase::kDraining) {
    finish_drain(ctx);
  }
}

void delivery_transport_result(const TransportResult& result, const At& at,
                               EngineState* state, Output* out) {
  DeliveryContext ctx{state, at, out};
  apply_transport_result(ctx, result);
}

void delivery_flush_requested(const At& at, EngineState* state, Output* out) {
  DeliveryContext ctx{state, at, out};
  request_pass(ctx);
}

void delivery_user_changed(const At& at, EngineState* state, Output* out) {
  DeliveryContext ctx{state, at, out};
  identity_changed(ctx, true);
}

void delivery_traits_changed(const At& at, EngineState* state,
                             Output* out) {
  DeliveryContext ctx{state, at, out};
  identity_changed(ctx, false);
}

void delivery_dispose(const At& at, EngineState* state, Output* out) {
  DeliveryContext ctx{state, at, out};
  reset(ctx);
  // The host destroys the engine next: nothing it uploads matters any more.
  FlushCursor& pass = state->delivery.pass;
  if (pass.in_flight) {
    state->timers.cancel(kAnswerTimerPrefix + pass.in_flight->request_id, out);
    for (const std::string& frame_id : pass.in_flight->frame_ids) {
      state->frame_retention.release(frame_id, FrameOwner::kDelivery, out);
    }
    pass.in_flight.reset();
  }
}

}  // namespace engine
}  // namespace tugboat
