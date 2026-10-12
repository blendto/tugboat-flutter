#include "frame_ledger.h"

#include <utility>
#include <vector>

namespace tugboat {
namespace engine {

void FrameLedger::reset() {
  provenance_.clear();
  latest_frame_id_.reset();
  sequence_ = 0;
}

const FrameProvenance* FrameLedger::find(const std::string& frame_id) const {
  const auto it = provenance_.find(frame_id);
  return it == provenance_.end() ? nullptr : &it->second;
}

const FrameProvenance* FrameLedger::latest(
    const std::string& session_id) const {
  if (!latest_frame_id_) return nullptr;
  const FrameProvenance* frame = find(*latest_frame_id_);
  if (frame == nullptr || !frame->available ||
      frame->session_id != session_id) {
    return nullptr;
  }
  return frame;
}

std::string FrameLedger::accept(const CapturedFrame& captured,
                                FrameTrigger trigger, int64_t at_ms,
                                int64_t max_frames, IdCounter* ids,
                                Session* session, Output* out) {
  // Dart `_publishPhysicalCaptureResult`.
  Frame frame;
  frame.id = ids->next("frame");
  frame.at_ms = at_ms;
  frame.width = captured.width;
  frame.height = captured.height;
  frame.content_hash = captured.content_hash;
  frame.masked = captured.masked;
  frame.trigger = trigger;
  frame.byte_length = captured.byte_length;
  frame.capture_micros = captured.capture_micros;
  frame.capture_session_id = session->id();
  frame.requested_backend = captured.requested_backend;
  frame.resolved_backend = captured.resolved_backend;
  frame.fallback_reason = captured.fallback_reason;

  FrameProvenance provenance;
  provenance.frame_id = frame.id;
  provenance.session_id = session->id();
  provenance.completed_at_ms = at_ms;
  provenance.sequence = ++sequence_;
  provenance.pixel_width = captured.width;
  provenance.pixel_height = captured.height;
  provenance.boundary = captured.boundary;
  provenance_[frame.id] = provenance;
  latest_frame_id_ = frame.id;

  const std::string id = frame.id;
  out->records.push_back(FrameRecord{captured.handle, frame});
  // A trimmed frame keeps a tombstone so it can never be attached again.
  for (const std::string& dropped :
       session->append_frame(std::move(frame), max_frames)) {
    provenance_[dropped].available = false;
  }
  return id;
}

CaptureResolution FrameLedger::resolve(
    CaptureResultOutcome outcome, const std::optional<CapturedFrame>& frame,
    FrameTrigger trigger, int64_t at_ms, int64_t max_frames, IdCounter* ids,
    Session* session, Output* out) {
  switch (outcome) {
    case CaptureResultOutcome::kCaptured:
      return {CaptureOutcome::kFreshAccepted,
              accept(*frame, trigger, at_ms, max_frames, ids, session, out)};
    case CaptureResultOutcome::kPaintUnchanged: {
      // Dart `_reuseWithoutCapture`: the latest frame stands in, if any.
      const FrameProvenance* reused = latest(session->id());
      if (reused == nullptr) return {CaptureOutcome::kNoCompatibleFrame, {}};
      return {CaptureOutcome::kPaintGenerationUnchanged, reused->frame_id};
    }
    case CaptureResultOutcome::kFailed:
      return {CaptureOutcome::kCaptureProcessingFailed, {}};
    case CaptureResultOutcome::kCancelled:
      return {CaptureOutcome::kCancelled, {}};
  }
  return {CaptureOutcome::kCancelled, {}};
}

OptString FrameLedger::observed_after(
    const OptString& frame_id, const ObservationBoundary& boundary) const {
  if (!frame_id) return std::nullopt;
  const FrameProvenance* frame = find(*frame_id);
  if (frame == nullptr || !frame->available ||
      frame->session_id != boundary.session_id ||
      frame->completed_at_ms < boundary.at_ms) {
    return std::nullopt;
  }
  if (boundary.after_sequence && frame->sequence <= *boundary.after_sequence) {
    return std::nullopt;
  }
  return frame_id;
}

}  // namespace engine
}  // namespace tugboat
