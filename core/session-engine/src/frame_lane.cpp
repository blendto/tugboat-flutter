#include "frame_lane.h"

#include <algorithm>
#include <utility>

#include "delivery_bounds.h"

namespace tugboat {
namespace engine {

void FrameReferences::mark_referenced(const std::string& frame_id) {
  if (finished_.count(frame_id) == 0) {
    referenced_.insert(frame_id);
  }
}

void FrameReferences::finish(const std::string& frame_id, size_t cap) {
  referenced_.erase(frame_id);
  if (finished_.insert(frame_id).second) {
    finished_order_.push_back(frame_id);
  }
  while (finished_order_.size() > cap) {
    finished_.erase(finished_order_.front());
    finished_order_.pop_front();
  }
}

void FrameReferences::clear() {
  referenced_.clear();
  finished_order_.clear();
  finished_.clear();
}

namespace {

// `byteLength` is any non-negative int64; a frame counts for at most the
// configuration ceiling (config.cpp, 2^40), so the sum over at most
// `kMaxCount` frames cannot overflow.
constexpr int64_t kMaxCountedBytes = int64_t{1} << 40;

int64_t counted_bytes(const PendingFrame& frame) {
  return std::min(frame.bytes, kMaxCountedBytes);
}

// The frame to evict: the oldest nothing references, never the newest (the
// event that points at it usually arrives just after); else the oldest.
size_t eviction_index(const std::deque<PendingFrame>& pending,
                      const FrameReferences& references) {
  for (size_t i = 0; i + 1 < pending.size(); ++i) {
    if (!references.referenced(pending[i].frame_id)) {
      return i;
    }
  }
  return 0;
}

}  // namespace

FrameEviction FrameLane::push(PendingFrame frame, const FrameBounds& bounds,
                              const FrameReferences& references) {
  pending_.push_back(std::move(frame));
  return trim(bounds, references);
}

FrameEviction FrameLane::requeue_front(FrameUploads uploads,
                                       const FrameBounds& bounds,
                                       const FrameReferences& references) {
  pending_.insert(pending_.begin(), std::make_move_iterator(uploads.begin()),
                  std::make_move_iterator(uploads.end()));
  return trim(bounds, references);
}

FrameEviction FrameLane::trim(const FrameBounds& bounds,
                              const FrameReferences& references) {
  int64_t bytes = 0;
  for (const PendingFrame& frame : pending_) {
    bytes += counted_bytes(frame);
  }
  FrameEviction evicted;
  while (!pending_.empty() &&
         (pending_.size() > bounds.frames || bytes > bounds.bytes)) {
    const size_t index = eviction_index(pending_, references);
    PendingFrame frame = std::move(pending_[index]);
    pending_.erase(pending_.begin() + static_cast<std::ptrdiff_t>(index));
    bytes -= counted_bytes(frame);
    if (references.referenced(frame.frame_id)) {
      ++evicted.referenced;
    }
    evicted.frames.push_back(std::move(frame));
  }
  return evicted;
}

FrameUploads FrameLane::take_batch(size_t max) {
  std::stable_sort(pending_.begin(), pending_.end(),
                   [](const PendingFrame& a, const PendingFrame& b) {
                     return a.frame_no < b.frame_no;
                   });
  const size_t count = std::min(max, pending_.size());
  FrameUploads batch(std::make_move_iterator(pending_.begin()),
                     std::make_move_iterator(pending_.begin() +
                                             static_cast<std::ptrdiff_t>(count)));
  pending_.erase(pending_.begin(),
                 pending_.begin() + static_cast<std::ptrdiff_t>(count));
  return batch;
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
