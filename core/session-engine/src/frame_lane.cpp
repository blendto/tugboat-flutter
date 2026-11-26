#include "frame_lane.h"

#include <algorithm>
#include <limits>
#include <utility>

#include "delivery_bounds.h"

namespace tugboat {
namespace engine {

bool frame_number(const std::string& frame_id, int64_t* out) {
  size_t start = frame_id.size();
  while (start > 0 && frame_id[start - 1] >= '0' &&
         frame_id[start - 1] <= '9') {
    --start;
  }
  if (start == frame_id.size()) {
    return false;
  }
  int64_t value = 0;
  constexpr int64_t kMax = std::numeric_limits<int64_t>::max();
  for (size_t i = start; i < frame_id.size(); ++i) {
    const int digit = frame_id[i] - '0';
    if (value > (kMax - digit) / 10) {
      return false;
    }
    value = value * 10 + digit;
  }
  *out = value;
  return true;
}

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
