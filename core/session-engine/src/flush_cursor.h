// The flush pass cursor (docs/stateful-engine.md section 7.3) as plain data:
// whether a pass runs, the one request in flight, the frames the pass took,
// and what runs after the pass. The transitions are in flush_pass.cpp; the
// request in flight names the step the pass is waiting in. Not part of the
// C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_FLUSH_CURSOR_H
#define TUGBOAT_SESSION_ENGINE_FLUSH_CURSOR_H

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "event_queue.h"
#include "frame_lane.h"

namespace tugboat {
namespace engine {

// What the request in flight carries, which is the pass step it answers
// (Dart `_flushOnce`): the lifecycle head; a frame chunk, or one frame of a
// chunk rejected with 400; the retry head; a fresh batch.
enum class RequestKind {
  kLifecycle,
  kFrameChunk,   // FrameCursor chunk [chunk_begin, chunk_end)
  kFrameSingle,  // FrameCursor upload isolate_index (400 isolation)
  kRetryBatch,
  kFreshBatch,   // InFlight::batch
};

// Dart `_flushFrames`' locals: the batch being uploaded (at most
// `frameChunk` frames, the lowest numbers first), how many of the frames
// pending when the step began are still to be taken, and the 400 isolation
// state. Frames captured during the step wait for the next one.
struct FrameCursor {
  FrameUploads uploads;  // the batch in flight: `[0, uploads.size())`
  size_t remaining = 0;
  size_t chunk_begin = 0;  // always 0: the batch is the chunk
  size_t chunk_end = 0;    // `uploads.size()`
  // 400 isolation: the frame of the chunk being re-sent alone, and whether
  // one of them was dropped.
  size_t isolate_index = 0;
  bool isolate_dropped = false;
  // Whether any chunk of this pass was dropped (no `recovered` then).
  bool dropped_batch = false;
};

struct InFlight {
  std::string request_id;  // `http-N`
  RequestKind kind = RequestKind::kLifecycle;
  // The delivery this request belonged to was reset (a new session). Its
  // answer is ignored, but it still holds the single request slot.
  bool orphaned = false;
  EventBatch batch;                    // kFreshBatch: requeued on retry
  std::vector<std::string> frame_ids;  // frame uploads: frames being read
  int64_t sent_mono_us = 0;
  // A request whose session was replaced still holds its items until it
  // settles (Dart `_inFlightEvents` and `_inFlightFrames`): `orphan_pending`
  // of them count as pending, and settling it counts as dropped
  // `lost_on_retry` items when the collector left it to retry and
  // `lost_otherwise` when not (Dart `_settleStaleRequest` and
  // `_settleStaleFrames`; frames the replaced session never got to send are
  // lost either way).
  int64_t orphan_pending = 0;
  int64_t lost_on_retry = 0;
  int64_t lost_otherwise = 0;
};

// The flush pass step a request or wait belongs to, for timing (Dart
// `_FlushTiming`).
enum class PassStep { kSessions, kFrames, kEventRetries, kEvents };

struct FlushCursor {
  bool running = false;  // a pass is between its first and last step
  FrameCursor frames;
  std::optional<InFlight> in_flight;  // at most one request at a time
  // A trigger arrived during a pass: run another when it ends (change C2).
  bool follow_up = false;
  // Dart `_drainLifecyclePosts`: while set, a pass that ends with a new
  // lifecycle head runs another pass. Holds the head the drain last saw.
  std::optional<uint64_t> drain_head;
  // Events still to send in this pass: only those queued when the drain
  // began (Dart `_drainPendingEvents`), so a busy session cannot keep frames
  // waiting.
  size_t events_remaining = 0;
  // The frames step was entered between event batches: it continues with the
  // next batch rather than the retry batches.
  bool frames_between_events = false;
  // Timing (Dart `_FlushTiming`): when the pass began and the time spent in
  // each step.
  int64_t started_mono_us = 0;
  std::array<int64_t, 4> step_us = {0, 0, 0, 0};
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_FLUSH_CURSOR_H
