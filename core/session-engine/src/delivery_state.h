// Collector delivery state (docs/stateful-engine.md section 7): lanes,
// queues, the flush cursor, and in-flight requests. Owned by the delivery
// module (delivery.cpp, flush_pass.cpp, delivery_lanes.cpp). The traits bag
// is host identity (`EngineState::identity`).
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DELIVERY_STATE_H
#define TUGBOAT_SESSION_ENGINE_DELIVERY_STATE_H

#include <cstdint>
#include <optional>

#include "clock.h"
#include "config.h"
#include "delivery_gaps.h"
#include "event_queue.h"
#include "flush_cursor.h"
#include "frame_lane.h"
#include "host.h"
#include "json.h"
#include "lifecycle_lane.h"

namespace tugboat {
namespace engine {

// Where delivery is in the session's life (design section 4.2 `ending`):
//   kOff       no session yet, or collector delivery is disabled;
//   kActive    the session is live;
//   kDraining  the session ended; frames and events drain before
//              `session_end` is queued (change C5);
//   kEnded     `session_end` is queued; delivery keeps retrying until the
//              lanes are empty, then stops its periodic timer.
// A new `session.start` resets delivery.
enum class DeliveryPhase { kOff, kActive, kDraining, kEnded };

struct DeliveryState {
  DeliveryPhase phase = DeliveryPhase::kOff;
  // The host and collector settings the session started with; a later
  // `engine.configure` applies from the next session.
  std::optional<Host> host;
  CollectorConfig config;

  // `ids.traits_id` survives sessions; `ids.session_id` is per session.
  CollectorIds ids;

  LifecycleLane lifecycle;
  IdentityDebounce debounce;
  // `session_end`, held while frames and events drain (change C5).
  std::optional<At> held_session_end;
  EventQueue events;
  FrameLane frames;
  // Dart `_framesNeedRetry`: frame arrival does not trigger a pass.
  bool frames_need_retry = false;
  FrameGaps frame_gaps;
  EventGaps event_gaps;

  FlushCursor pass;
  int64_t next_request = 0;  // `http-N`, per engine handle, never reset
  int64_t flush_deadline_us = 0;  // the periodic timer's current deadline
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DELIVERY_STATE_H
