#include "capture_seam.h"

#include <utility>
#include <vector>

namespace tugboat {
namespace engine {

CaptureAsk interaction_capture(int64_t now_mono_us, CaptureContext context) {
  CaptureAsk ask;
  ask.trigger = FrameTrigger::kInteraction;
  ask.force = true;
  // Dart `_captureFreshnessFor`: interaction captures need a fresh paint.
  ask.require_fresh_paint = true;
  ask.not_before_mono_us = now_mono_us;
  ask.context = std::move(context);
  return ask;
}

void CaptureSeam::reset() {
  requests_.clear();
  provenance_.clear();
  latest_frame_id_.reset();
  sequence_ = 0;
}

std::string CaptureSeam::issue(const CaptureOwner& owner,
                               const CaptureAsk& ask, IdCounter* ids,
                               Output* out) {
  CaptureRequest request;
  request.request_id = ids->next("capture_request");
  request.trigger = ask.trigger;
  request.force = ask.force;
  request.require_fresh_paint = ask.require_fresh_paint;
  request.drop_when_busy = false;
  request.not_before_mono_us = ask.not_before_mono_us;
  request.context = ask.context;
  request.scale = 1.0;
  requests_[request.request_id] = Request{owner, ask.trigger};
  out->effects.push_back(request);
  return request.request_id;
}

std::optional<CaptureAnswer> CaptureSeam::on_result(
    const CaptureResult& result, int64_t at_ms, int64_t max_frames,
    IdCounter* ids, Session* session, Output* out) {
  const auto it = requests_.find(result.request_id);
  if (it == requests_.end()) return std::nullopt;
  CaptureAnswer answer;
  answer.owner = it->second.owner;
  const FrameTrigger trigger = it->second.trigger;
  requests_.erase(it);
  switch (result.outcome) {
    case CaptureResultOutcome::kCaptured: {
      answer.accepted = accept(*result.frame, trigger, at_ms, max_frames, ids,
                               session, out);
      answer.resolution = {CaptureOutcome::kFreshAccepted,
                           answer.accepted->frame.id};
      break;
    }
    case CaptureResultOutcome::kPaintUnchanged: {
      // Dart `_reuseWithoutCapture`: the latest frame stands in, if any.
      const FrameProvenance* reused = latest(session->id());
      answer.resolution =
          reused == nullptr
              ? CaptureResolution{CaptureOutcome::kNoCompatibleFrame, {}}
              : CaptureResolution{CaptureOutcome::kPaintGenerationUnchanged,
                                  reused->frame_id};
      break;
    }
    case CaptureResultOutcome::kFailed:
      answer.resolution = {CaptureOutcome::kCaptureProcessingFailed, {}};
      break;
    case CaptureResultOutcome::kCancelled:
      answer.resolution = {CaptureOutcome::kCancelled, {}};
      break;
  }
  return answer;
}

FrameRecord CaptureSeam::accept(const CapturedFrame& captured,
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

  const FrameRecord record{captured.handle, frame};
  out->records.push_back(record);
  // A trimmed frame keeps a tombstone so it can never be attached again.
  for (const std::string& dropped :
       session->append_frame(std::move(frame), max_frames)) {
    provenance_[dropped].available = false;
  }
  return record;
}

const FrameProvenance* CaptureSeam::find(const std::string& frame_id) const {
  const auto it = provenance_.find(frame_id);
  return it == provenance_.end() ? nullptr : &it->second;
}

const FrameProvenance* CaptureSeam::latest(
    const std::string& session_id) const {
  if (!latest_frame_id_) return nullptr;
  const FrameProvenance* frame = find(*latest_frame_id_);
  if (frame == nullptr || !frame->available ||
      frame->session_id != session_id) {
    return nullptr;
  }
  return frame;
}

OptString CaptureSeam::observed_after(
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
