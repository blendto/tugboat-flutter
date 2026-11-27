#include "delivery_gaps.h"

#include <utility>

namespace tugboat {
namespace engine {

namespace {

bool is_power_of_two(int64_t n) { return n > 0 && (n & (n - 1)) == 0; }

// Bit length: a cumulative count crosses a power of two when it grows.
int bit_length(int64_t n) {
  int bits = 0;
  for (; n > 0; n >>= 1) {
    ++bits;
  }
  return bits;
}

}  // namespace

GapReport FrameGaps::report(const char* result, std::optional<int64_t> status,
                            int64_t frame_count) {
  Value data = Value::object();
  data.set("component", Value::string("collector_frame_upload"));
  data.set("result", Value::string(result));
  if (status) {
    data.set("statusCode", Value::integer(*status));
  }
  data.set("frameCount", Value::integer(frame_count));
  data.set("droppedFrameCount", Value::integer(dropped_frames_));
  return GapReport{"collector-frame-upload-" + std::to_string(sequence_++),
                   std::move(data)};
}

std::optional<GapReport> FrameGaps::failed(std::optional<int64_t> status,
                                           int64_t frame_count) {
  if (failure_reported_) {
    return std::nullopt;
  }
  failure_reported_ = true;
  return report("failed", status, frame_count);
}

std::optional<GapReport> FrameGaps::flushed(bool dropped_batch) {
  if (!failure_reported_ || dropped_batch) {
    return std::nullopt;
  }
  failure_reported_ = false;
  return report("recovered", std::nullopt, 0);
}

std::optional<GapReport> FrameGaps::evicted(int64_t count) {
  if (count == 0) {
    return std::nullopt;
  }
  dropped_frames_ += count;
  if (!is_power_of_two(dropped_frames_)) {
    return std::nullopt;
  }
  return report("dropped", std::nullopt, dropped_frames_);
}

std::optional<GapReport> EventGaps::dropped(EventDropReason reason,
                                            int64_t count,
                                            std::optional<int64_t> status) {
  if (count == 0) {
    return std::nullopt;
  }
  const int before = bit_length(dropped_events_);
  dropped_events_ += count;
  if (bit_length(dropped_events_) == before) {
    return std::nullopt;
  }
  Value data = Value::object();
  data.set("component", Value::string("collector_event_upload"));
  data.set("result", Value::string("dropped"));
  data.set("reason", Value::string(reason == EventDropReason::kEvicted
                                       ? "evicted"
                                       : "rejected"));
  if (status) {
    data.set("statusCode", Value::integer(*status));
  }
  data.set("eventCount", Value::integer(count));
  data.set("droppedEventCount", Value::integer(dropped_events_));
  return GapReport{"collector-event-upload-" + std::to_string(sequence_++),
                   std::move(data)};
}

}  // namespace engine
}  // namespace tugboat
