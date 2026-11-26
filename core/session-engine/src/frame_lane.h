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
  Value metadata;  // TugboatFrame.toJson() when the frame was added
};

using FrameUploads = std::vector<PendingFrame>;

// `frameNumberFromId`: the trailing decimal digits of an engine frame id
// (`frame-N`). False when there are none or they overflow.
bool frame_number(const std::string& frame_id, int64_t* out);

class FrameLane {
 public:
  // Appends a frame, then evicts the oldest beyond `bound` (returned).
  FrameUploads push(PendingFrame frame, size_t bound);
  // Puts uploads that must be retried back at the front, in order, then
  // evicts the oldest beyond `bound`: requeued frames go first.
  FrameUploads requeue_front(FrameUploads uploads, size_t bound);
  // Removes every pending frame, sorted by frame number (stable).
  FrameUploads take_sorted();
  FrameUploads take_all();
  bool empty() const { return pending_.empty(); }
  size_t size() const { return pending_.size(); }

 private:
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
