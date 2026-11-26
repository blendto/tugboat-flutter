#include "frame_lane.h"

#include <algorithm>
#include <utility>

#include "delivery_bounds.h"

namespace tugboat {
namespace engine {

FrameUploads FrameLane::push(PendingFrame frame, size_t bound) {
  pending_.push_back(std::move(frame));
  return evict_oldest(&pending_, bound);
}

FrameUploads FrameLane::requeue_front(FrameUploads uploads, size_t bound) {
  pending_.insert(pending_.begin(), std::make_move_iterator(uploads.begin()),
                  std::make_move_iterator(uploads.end()));
  return evict_oldest(&pending_, bound);
}

FrameUploads FrameLane::take_sorted() {
  FrameUploads uploads = take_all();
  std::stable_sort(uploads.begin(), uploads.end(),
                   [](const PendingFrame& a, const PendingFrame& b) {
                     return a.frame_no < b.frame_no;
                   });
  return uploads;
}

FrameUploads FrameLane::take_all() {
  FrameUploads uploads(std::make_move_iterator(pending_.begin()),
                       std::make_move_iterator(pending_.end()));
  pending_.clear();
  return uploads;
}

MultipartBody frame_upload_body(const std::string& session_id,
                                const FrameUploads& uploads, size_t begin,
                                size_t end) {
  std::string frame_nos;
  Value metadata = Value::array();
  MultipartBody body;
  for (size_t i = begin; i < end; ++i) {
    const std::string number = std::to_string(uploads[i].frame_no);
    frame_nos += (i == begin ? "" : ",") + number;
    metadata.push(uploads[i].metadata);
    body.frames.push_back({uploads[i].handle, number + ".jpg"});
  }
  body.fields.emplace_back("sessionId", session_id);
  body.fields.emplace_back("frameNos", frame_nos);
  body.fields.emplace_back("frameMetadata", encode_json(metadata));
  return body;
}

}  // namespace engine
}  // namespace tugboat
