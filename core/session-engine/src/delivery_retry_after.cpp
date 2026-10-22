#include "delivery_retry_after.h"

#include "delivery_state.h"
#include "flush_cursor.h"
#include "retry_after.h"

namespace tugboat {
namespace engine {

namespace {

size_t lane_index(HttpLane lane) {
  switch (lane) {
    case HttpLane::kLifecycle:
      return 0;
    case HttpLane::kEvents:
      return 1;
    case HttpLane::kFrames:
      return 2;
  }
  return 0;
}

HttpLane lane_from_timer_suffix(const std::string& suffix) {
  if (suffix == "lifecycle") {
    return HttpLane::kLifecycle;
  }
  if (suffix == "events") {
    return HttpLane::kEvents;
  }
  return HttpLane::kFrames;
}

}  // namespace

HttpLane http_lane_for_request(RequestKind kind) {
  switch (kind) {
    case RequestKind::kLifecycle:
      return HttpLane::kLifecycle;
    case RequestKind::kFrameChunk:
    case RequestKind::kFrameSingle:
      return HttpLane::kFrames;
    case RequestKind::kRetryBatch:
    case RequestKind::kFreshBatch:
      return HttpLane::kEvents;
  }
  return HttpLane::kEvents;
}

bool lane_send_blocked(const DeliveryContext& ctx, HttpLane lane) {
  const DeliveryState& d = ctx.delivery();
  const int64_t not_before = d.lane_send_not_before_mono_us[lane_index(lane)];
  return not_before > ctx.at.mono_us;
}

void cancel_lane_retry_after_timers(DeliveryContext& ctx) {
  for (const char* suffix : {"lifecycle", "events", "frames"}) {
    std::string timer_id = kRetryAfterTimerPrefix;
    timer_id += suffix;
    ctx.state->timers.cancel(timer_id, ctx.out);
  }
  DeliveryState& d = ctx.delivery();
  d.lane_send_not_before_mono_us = {0, 0, 0};
}

void maybe_arm_lane_retry_after(DeliveryContext& ctx, HttpLane lane,
                                const TransportResult& result) {
  if (classify(result) != Verdict::kRetry || !result.status ||
      !result.retry_after) {
    return;
  }
  const int64_t status = *result.status;
  if (status != 429 && status != 503) {
    return;
  }
  const int64_t wall_us = ctx.at.wall_us.value_or(0);
  const std::optional<int64_t> delay_ms = parse_retry_after_delay_ms(
      *result.retry_after, wall_us, ctx.config().max_retry_after_ms);
  if (!delay_ms || *delay_ms <= 0) {
    return;
  }
  DeliveryState& d = ctx.delivery();
  const size_t index = lane_index(lane);
  const int64_t not_before = ctx.at.mono_us + *delay_ms * 1000;
  d.lane_send_not_before_mono_us[index] = not_before;
  std::string timer_id = kRetryAfterTimerPrefix;
  timer_id += http_lane_name(lane);
  ctx.state->timers.schedule(timer_id, not_before, ctx.out);
}

bool delivery_retry_after_timer_fired(const std::string& timer_id,
                                      DeliveryContext& ctx) {
  const std::string prefix = kRetryAfterTimerPrefix;
  if (timer_id.compare(0, prefix.size(), prefix) != 0) {
    return false;
  }
  const HttpLane lane =
      lane_from_timer_suffix(timer_id.substr(prefix.size()));
  DeliveryState& d = ctx.delivery();
  d.lane_send_not_before_mono_us[lane_index(lane)] = 0;
  request_pass(ctx);
  return true;
}

}  // namespace engine
}  // namespace tugboat
