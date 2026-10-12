// The capture seam (design section 8.2): the one interface through which
// the engine asks the host for frames and learns what they were. Phase 3c
// implements the minimum interactions need; phase 3d replaces this
// implementation with the capture scheduler (FIFO and tail absorption,
// suppression, budget, reuse, coalescing, dedupe, compatibility) behind the
// same interface.
//
// It owns:
// - the outstanding `capture.request` effects and who waits for each answer
//   (principle 4: answers to unknown or invalidated ids are ignored);
// - frame acceptance: a `captured` answer becomes `frame-N`, a frame record,
//   and a session frame;
// - frame provenance: the latest frame of a session (the before-frame), and
//   whether a frame is an observation made after some input.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_SEAM_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_SEAM_H

#include <cstdint>
#include <map>
#include <optional>
#include <string>

#include "frame_retention.h"
#include "models.h"
#include "output.h"
#include "session.h"

namespace tugboat {
namespace engine {

// The capture boundary in surface logical pixels when a frame was taken.
struct BoundaryRect {
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
};

// A frame the host captured (`capture.result` `frame` plus `boundaryRect`).
// The bytes stay in the host under `handle`.
struct CapturedFrame {
  std::string handle;
  int64_t width = 0;
  int64_t height = 0;
  std::string content_hash;
  bool masked = false;
  int64_t byte_length = 0;
  int64_t capture_micros = 0;
  OptString requested_backend;
  OptString resolved_backend;
  OptString fallback_reason;
  std::optional<BoundaryRect> boundary;
};

// The `capture.result` outcomes the host reports.
enum class CaptureResultOutcome {
  kCaptured,
  kPaintUnchanged,
  kFailed,
  kCancelled,
};

// `capture.result {requestId, outcome, frame?, boundaryRect?}`.
struct CaptureResult {
  std::string request_id;
  CaptureResultOutcome outcome = CaptureResultOutcome::kFailed;
  std::optional<CapturedFrame> frame;  // with `captured` only
};

// Who consumes a capture answer. `key` is the interaction id (tap settle,
// gesture), the scroll start id (scroll end), or the event id (focus or
// system-input observation).
struct CaptureOwner {
  enum class Kind { kTapSettle, kGesture, kScrollEnd, kObservation };
  Kind kind = Kind::kGesture;
  std::string key;
};

// What to ask the host for.
struct CaptureAsk {
  FrameTrigger trigger = FrameTrigger::kInteraction;
  bool force = false;
  bool require_fresh_paint = false;
  int64_t not_before_mono_us = 0;
  CaptureContext context;
};

// A completed gesture asks for a fresh `interaction` frame now (Dart:
// `trigger: interaction, force: true, settleDelay: zero`).
CaptureAsk interaction_capture(int64_t now_mono_us, CaptureContext context);

// Dart `_CaptureOutcome`, for the outcomes phase 3c can produce.
enum class CaptureOutcome {
  kFreshAccepted,
  kPaintGenerationUnchanged,
  kNoCompatibleFrame,
  kCaptureProcessingFailed,
  kCancelled,
};

// What one capture request resolved to (Dart `_CaptureResolution`).
struct CaptureResolution {
  CaptureOutcome outcome = CaptureOutcome::kCancelled;
  OptString frame_id;
};

// An answer routed back to its owner. `accepted` is the frame this answer
// added to the session (its record is already emitted), if any.
struct CaptureAnswer {
  CaptureOwner owner;
  CaptureResolution resolution;
  std::optional<FrameRecord> accepted;
};

// Dart `_FrameProvenance`, reduced to what interactions read.
struct FrameProvenance {
  std::string frame_id;
  std::string session_id;
  int64_t completed_at_ms = 0;
  int64_t sequence = 0;
  int64_t pixel_width = 0;
  int64_t pixel_height = 0;
  std::optional<BoundaryRect> boundary;
  // False once the frame is trimmed from the session (a tombstone).
  bool available = true;
};

// The input a temporal observation must follow (Dart `_temporalAfterFrame`
// and `_frameObservedAfter`).
struct ObservationBoundary {
  std::string session_id;
  int64_t at_ms = 0;
  // When set, the frame's sequence must be greater (the frame completion
  // sequence at pointer-up).
  std::optional<int64_t> after_sequence;
};

class CaptureSeam {
 public:
  // Session start: forgets every frame and outstanding request.
  void reset();
  // Teardown: invalidates every outstanding request; late answers are then
  // ignored.
  void cancel_requests() { requests_.clear(); }

  // Mints `capture_request-N`, emits `capture.request`, and remembers the
  // owner. Returns the request id.
  std::string issue(const CaptureOwner& owner, const CaptureAsk& ask,
                    IdCounter* ids, Output* out);

  // Resolves the answer to an outstanding request, or nothing for an
  // unknown id. A `captured` frame is accepted into `session` as `frame-N`
  // completing at `at_ms`: appended (trimming beyond `max_frames`, which
  // tombstones provenance) and emitted as a frame record. The session's
  // reference to its handle starts in `retention`, and trimmed frames lose
  // theirs (section 7.6). `paintUnchanged` reuses the session's latest frame.
  std::optional<CaptureAnswer> on_result(const CaptureResult& result,
                                         int64_t at_ms, int64_t max_frames,
                                         IdCounter* ids, Session* session,
                                         FrameRetention* retention,
                                         Output* out);

  // The frame completion sequence: how many frames this session accepted.
  int64_t sequence() const { return sequence_; }
  // The latest available frame of `session_id`, or nullptr.
  const FrameProvenance* latest(const std::string& session_id) const;
  const FrameProvenance* find(const std::string& frame_id) const;

  // `frame_id` when it is an available frame of the boundary's session that
  // completed at or after `boundary.at_ms` (and, when set, after its
  // sequence); otherwise nothing.
  OptString observed_after(const OptString& frame_id,
                           const ObservationBoundary& boundary) const;

 private:
  struct Request {
    CaptureOwner owner;
    FrameTrigger trigger;
  };

  FrameRecord accept(const CapturedFrame& frame, FrameTrigger trigger,
                     int64_t at_ms, int64_t max_frames, IdCounter* ids,
                     Session* session, FrameRetention* retention,
                     Output* out);

  std::map<std::string, Request> requests_;
  std::map<std::string, FrameProvenance> provenance_;
  OptString latest_frame_id_;
  int64_t sequence_ = 0;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_SEAM_H
