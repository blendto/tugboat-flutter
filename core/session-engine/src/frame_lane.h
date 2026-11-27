// The collector frames lane (docs/stateful-engine.md sections 7.5 and 7.6):
// frames waiting for upload, and the multipart body of one upload.
// Reproduces `CollectorHttpSink`'s `_pendingFrames` and
// `_frameUploadRequest`. Frame bytes never enter the engine: an upload names
// each frame's host handle. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_FRAME_LANE_H
#define TUGBOAT_SESSION_ENGINE_FRAME_LANE_H

#include <cstddef>
#include <cstdint>
#include <deque>
#include <set>
#include <string>
#include <vector>

#include "json.h"
#include "output.h"

namespace tugboat {
namespace engine {

struct PendingFrame {
  int64_t frame_no = 0;
  std::string frame_id;
  std::string handle;
  Value metadata;  // TugboatFrame.toJson() plus triggeredAt when the frame was added
  int64_t bytes = 0;  // the encoded frame's size (`byteLength`)
};

using FrameUploads = std::vector<PendingFrame>;

// Frames an event points at (`beforeFrame` / `afterFrame`) outlive frames
// nothing references when the queue is over its bounds, and frames that left
// the queue are forgotten so a late event does not mark them again (Dart
// `_referencedFrameNos` and `_finishedFrameNos`). Keyed by frame id.
class FrameReferences {
 public:
  // An event points at `frame_id`; ignored once that frame finished.
  void mark_referenced(const std::string& frame_id);
  bool referenced(const std::string& frame_id) const {
    return referenced_.count(frame_id) != 0;
  }
  // The frame left the queue (uploaded, rejected, or evicted). The finished
  // set keeps at most `cap` ids, oldest forgotten first.
  void finish(const std::string& frame_id, size_t cap);
  void clear();

 private:
  std::set<std::string> referenced_;
  std::deque<std::string> finished_order_;
  std::set<std::string> finished_;
};

// The queue's bounds: frames and encoded bytes.
struct FrameBounds {
  size_t frames = 0;
  int64_t bytes = 0;
};

// What an eviction removed.
struct FrameEviction {
  FrameUploads frames;  // oldest first
  size_t referenced = 0;  // how many of them an event pointed at

  bool empty() const { return frames.empty(); }
};

class FrameLane {
 public:
  // Appends a frame, then evicts beyond `bounds` (returned): the oldest
  // frame no event references first, else the oldest, and never the newest
  // while another frame could go (Dart `_trimPendingFrames`).
  FrameEviction push(PendingFrame frame, const FrameBounds& bounds,
                     const FrameReferences& references);
  // Puts uploads that must be retried back at the front, in order, then
  // evicts as `push` does.
  FrameEviction requeue_front(FrameUploads uploads, const FrameBounds& bounds,
                              const FrameReferences& references);
  // Removes every pending frame, sorted by frame number (stable).
  FrameUploads take_sorted();
  // Removes the `max` lowest-numbered pending frames, sorted (Dart
  // `_takeFrameBatch`).
  FrameUploads take_batch(size_t max);
  FrameUploads take_all();
  bool empty() const { return pending_.empty(); }
  size_t size() const { return pending_.size(); }

 private:
  FrameEviction trim(const FrameBounds& bounds,
                     const FrameReferences& references);

  std::deque<PendingFrame> pending_;
};

// The `/v1/frames` multipart body for `uploads[begin, end)`: fields
// `sessionId`, `frameNos` (comma-joined), and `frameMetadata` (the frames'
// JSON array in file order), then one `<frameNo>.jpg` file per frame.
MultipartBody frame_upload_body(const std::string& session_id,
                                const FrameUploads& uploads, size_t begin,
                                size_t end);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_FRAME_LANE_H
