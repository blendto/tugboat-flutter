// Per-lane `Retry-After` waits before the next send on that lane.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DELIVERY_RETRY_AFTER_H
#define TUGBOAT_SESSION_ENGINE_DELIVERY_RETRY_AFTER_H

#include "delivery_context.h"
#include "flush_cursor.h"
#include "output.h"
#include "transport.h"

namespace tugboat {
namespace engine {

constexpr char kRetryAfterTimerPrefix[] = "delivery.retryAfter.";

HttpLane http_lane_for_request(RequestKind kind);

bool lane_send_blocked(const DeliveryContext& ctx, HttpLane lane);

void cancel_lane_retry_after_timers(DeliveryContext& ctx);

void maybe_arm_lane_retry_after(DeliveryContext& ctx, HttpLane lane,
                                const TransportResult& result);

bool delivery_retry_after_timer_fired(const std::string& timer_id,
                                      DeliveryContext& ctx);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DELIVERY_RETRY_AFTER_H
