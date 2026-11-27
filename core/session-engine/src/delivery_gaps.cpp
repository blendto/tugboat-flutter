#include "delivery_gaps.h"

#include <utility>

namespace tugboat {
namespace engine {

namespace {

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
  data.set("droppedReferencedFrameCount",
           Value::integer(dropped_referenced_frames_));
  return GapReport{"collector-frame-upload", std::move(data)};
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

std::optional<GapReport> FrameGaps::evicted(int64_t count,
                                            int64_t referenced) {
  if (count == 0) {
    return std::nullopt;
  }
  dropped_frames_ += count;
  dropped_referenced_frames_ += referenced;
  if (dropped_frames_ < next_drop_report_at_) {
    return std::nullopt;
  }
  while (next_drop_report_at_ <= dropped_frames_) {
    next_drop_report_at_ *= 2;
  }
  reported_dropped_frames_ = dropped_frames_;
  return report("dropped", std::nullopt, dropped_frames_);
}

std::optional<GapReport> FrameGaps::final_drops() {
  if (dropped_frames_ <= reported_dropped_frames_) {
    return std::nullopt;
  }
  reported_dropped_frames_ = dropped_frames_;
  return report("dropped", std::nullopt, dropped_frames_);
}

std::optional<GapReport> FrameGaps::request_failed(
    const std::string& path, std::optional<int64_t> status,
    const char* error) {
  if (!failing_paths_.insert(path).second) {
    return std::nullopt;
  }
  Value data = Value::object();
  data.set("component", Value::string("collector_request"));
  data.set("path", Value::string(path));
  data.set("result", Value::string("failed"));
  if (status) {
    data.set("statusCode", Value::integer(*status));
  } else {
    data.set("error", Value::string(error));
  }
  return GapReport{"collector-request", std::move(data)};
}

std::optional<GapReport> FrameGaps::request_accepted(
    const std::string& path) {
  if (failing_paths_.erase(path) == 0) {
    return std::nullopt;
  }
  Value data = Value::object();
  data.set("component", Value::string("collector_request"));
  data.set("path", Value::string(path));
  data.set("result", Value::string("recovered"));
  return GapReport{"collector-request", std::move(data)};
}

std::optional<GapReport> FrameGaps::flush_pass(bool slow, bool awaiting_retry,
                                               int64_t duration_ms,
                                               const char* step,
                                               int64_t step_duration_ms) {
  if (!slow) {
    if (!awaiting_retry) {
      slow_flush_reported_ = false;
    }
    return std::nullopt;
  }
  if (slow_flush_reported_) {
    return std::nullopt;
  }
  slow_flush_reported_ = true;
  Value data = Value::object();
  data.set("component", Value::string("collector_flush"));
  data.set("result", Value::string("slow"));
  data.set("durationMs", Value::integer(duration_ms));
  data.set("step", Value::string(step));
  data.set("stepDurationMs", Value::integer(step_duration_ms));
  return GapReport{"collector-flush", std::move(data)};
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
  return GapReport{"collector-event-upload", std::move(data)};
}

}  // namespace engine
}  // namespace tugboat
