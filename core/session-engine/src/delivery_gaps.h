// Delivery gap diagnostics (docs/stateful-engine.md section 7.7). Decides
// when a gap is reported and what it says; the delivery module records it as
// an ordinary `capture_diagnostic` event record (change C6).
//
// Frame lane (`component: collector_frame_upload`, Dart's wire shape):
// - `failed`: the first upload failure, then latched until a later flush
//   uploads every frame without a drop, which reports `recovered`;
// - `dropped`: frames evicted from the pending queue, reported when the
//   cumulative count first reaches 1, 2, 4, 8, ...; the session's final
//   count is reported once more when it ends. Every frame record carries
//   `droppedFrameCount` and `droppedReferencedFrameCount` (evicted frames an
//   event pointed at).
// Request lane (`component: collector_request`): the first failed
// `/v1/sessions` or `/v1/events/batch` post per path and outage, then
// `recovered` on the path's next accepted post. Flush lane
// (`component: collector_flush`): the first slow flush pass of an outage.
// All of them draw ids from one per-session sequence.
// Event lane (`component: collector_event_upload`, opt-in with
// `reportEventLaneGaps`, change C6): `dropped` events, evicted or rejected,
// reported each time the cumulative count crosses a power of two.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DELIVERY_GAPS_H
#define TUGBOAT_SESSION_ENGINE_DELIVERY_GAPS_H

#include <cstdint>
#include <optional>
#include <set>
#include <string>

#include "json.h"

namespace tugboat {
namespace engine {

// A gap to record: the event id prefix and its `data`. The recorder mints
// the id as `<prefix>-<UUIDv4>` from the session's id stream (Dart 0.12.3
// `generateTugboatCaptureId`).
struct GapReport {
  std::string id_prefix;
  Value data;
};

// Dart `_reportFrameUploadFailure`, `_recordUploadDiagnostic`,
// `_trimPendingFrames`, `_noteRequestOutcome`, and `_reportSlowFlush`. Reset
// per session.
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
  // `count` pending frames were evicted, `referenced` of them pointed at by
  // an event. Reports when the cumulative count reaches the next power of
  // two.
  std::optional<GapReport> evicted(int64_t count, int64_t referenced = 0);
  // The session's final drop count when it was not reported yet.
  std::optional<GapReport> final_drops();

  // A `/v1/sessions` or `/v1/events/batch` post of `path` was not accepted:
  // `status` is the HTTP status, absent with `error` (`timeout` or
  // `transport`). Reported once per path until it recovers.
  std::optional<GapReport> request_failed(const std::string& path,
                                          std::optional<int64_t> status,
                                          const char* error);
  // An accepted post of `path`: `recovered` when it was failing.
  std::optional<GapReport> request_accepted(const std::string& path);

  // A flush pass took `duration_ms`; `slow` when it reached the threshold,
  // `awaiting_retry` when a lane still holds work the collector has not
  // accepted. Reports the first slow pass of an outage; a fast pass ends the
  // outage once nothing awaits a retry.
  std::optional<GapReport> flush_pass(bool slow, bool awaiting_retry,
                                      int64_t duration_ms, const char* step,
                                      int64_t step_duration_ms);

 private:
  GapReport report(const char* result, std::optional<int64_t> status,
                   int64_t frame_count);

  bool failure_reported_ = false;
  int64_t dropped_frames_ = 0;
  int64_t dropped_referenced_frames_ = 0;
  int64_t reported_dropped_frames_ = 0;
  int64_t next_drop_report_at_ = 1;
  std::set<std::string> failing_paths_;
  bool slow_flush_reported_ = false;
};

enum class EventDropReason { kEvicted, kRejected };

// Event-lane gaps (change C6, opt-in). Reset per session.
class EventGaps {
 public:
  // `count` events were dropped; `status` is the rejecting HTTP status.
  std::optional<GapReport> dropped(EventDropReason reason, int64_t count,
                                   std::optional<int64_t> status);

 private:
  int64_t dropped_events_ = 0;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DELIVERY_GAPS_H
