// Delivery gap diagnostics (docs/stateful-engine.md section 7.7). Decides
// when a gap is reported and what it says; the delivery module records it as
// an ordinary `capture_diagnostic` event record (change C6).
//
// Frame lane (`component: collector_frame_upload`, Dart's wire shape):
// - `failed`: the first upload failure, then latched until a later flush
//   uploads every frame without a drop, which reports `recovered`;
// - `dropped`: frames evicted from the pending queue, reported when the
//   cumulative count is 1 or a power of two.
// Event lane (`component: collector_event_upload`, opt-in with
// `reportEventLaneGaps`, change C6): `dropped` events, evicted or rejected,
// reported each time the cumulative count crosses a power of two.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DELIVERY_GAPS_H
#define TUGBOAT_SESSION_ENGINE_DELIVERY_GAPS_H

#include <cstdint>
#include <optional>
#include <string>

#include "json.h"

namespace tugboat {
namespace engine {

// A gap to record: the event id and its `data`.
struct GapReport {
  std::string id;
  Value data;
};

// Dart `_reportFrameUploadFailure`, `_recordUploadDiagnostic`, and
// `_trimPendingFrames`. Reset per session.
class FrameGaps {
 public:
  // An upload of `frame_count` frames failed (retry or drop outcome);
  // reported only when no failure is latched. `status` is absent for a
  // transport error or timeout.
  std::optional<GapReport> failed(std::optional<int64_t> status,
                                  int64_t frame_count);
  // A flush uploaded every pending frame. Reports `recovered` (and clears
  // the latch) when a failure was latched and nothing was dropped.
  std::optional<GapReport> flushed(bool dropped_batch);
  // `count` pending frames were evicted.
  std::optional<GapReport> evicted(int64_t count);

 private:
  GapReport report(const char* result, std::optional<int64_t> status,
                   int64_t frame_count);

  bool failure_reported_ = false;
  int64_t sequence_ = 0;
  int64_t dropped_frames_ = 0;
};

enum class EventDropReason { kEvicted, kRejected };

// Event-lane gaps (change C6, opt-in). Reset per session.
class EventGaps {
 public:
  // `count` events were dropped; `status` is the rejecting HTTP status.
  std::optional<GapReport> dropped(EventDropReason reason, int64_t count,
                                   std::optional<int64_t> status);

 private:
  int64_t sequence_ = 0;
  int64_t dropped_events_ = 0;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DELIVERY_GAPS_H
