// The flush pass cursor (docs/stateful-engine.md section 7.3) as plain data:
// whether a pass runs, the one request in flight, the frames the pass took,
// and what runs after the pass. The transitions are in flush_pass.cpp; the
// request in flight names the step the pass is waiting in. Not part of the
// C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_FLUSH_CURSOR_H
#define TUGBOAT_SESSION_ENGINE_FLUSH_CURSOR_H

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

// Dart `_flushFrames`' locals: the frames taken for this pass, sorted, and
// the chunk being uploaded.
struct FrameCursor {
  FrameUploads uploads;
  size_t chunk_begin = 0;
  size_t chunk_end = 0;
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
};

struct FlushCursor {
  bool running = false;  // a pass is between its first and last step
  FrameCursor frames;
  std::optional<InFlight> in_flight;  // at most one request at a time
  // A trigger arrived during a pass: run another when it ends (change C2).
  bool follow_up = false;
  // Dart `_drainLifecyclePosts`: while set, a pass that ends with a new
  // lifecycle head runs another pass. Holds the head the drain last saw.
  std::optional<uint64_t> drain_head;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_FLUSH_CURSOR_H
