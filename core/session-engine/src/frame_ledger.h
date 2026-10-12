// The frame ledger: the minimal frame provenance phase 3c needs, behind one
// small interface that phase 3d replaces with the full capture scheduler
// (decision order, reuse, coalescing, budget, compatibility; design section
// 8.2). It answers three questions:
// - which frame a pointer-down sees as its before-frame (the latest frame of
//   the session) and where the pointer lies on it;
// - how a `capture.result` resolves (a captured frame is accepted as a
//   fresh frame; `paintUnchanged` reuses the latest frame);
// - whether a frame is a temporal observation made after an input (same
//   session, completed no earlier, and newer than a frame sequence).
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_FRAME_LEDGER_H
#define TUGBOAT_SESSION_ENGINE_FRAME_LEDGER_H

#include <cstdint>
#include <map>
#include <optional>
#include <string>

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

// The `capture.result` outcomes the host reports.
enum class CaptureResultOutcome {
  kCaptured,
  kPaintUnchanged,
  kFailed,
  kCancelled,
};

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

// The input a temporal observation must follow (Dart `_temporalAfterFrame`
// and `_frameObservedAfter`).
struct ObservationBoundary {
  std::string session_id;
  int64_t at_ms = 0;
  // When set, the frame's sequence must be greater (the frame completion
  // sequence at pointer-up).
  std::optional<int64_t> after_sequence;
};

class FrameLedger {
 public:
  // Forgets every frame (session start).
  void reset();

  // The frame completion sequence: how many frames this session accepted.
  int64_t sequence() const { return sequence_; }

  // The latest available frame of `session_id`, or nullptr.
  const FrameProvenance* latest(const std::string& session_id) const;
  const FrameProvenance* find(const std::string& frame_id) const;

  // Resolves a `capture.result` for a request with `trigger`. A captured
  // frame is accepted into `session`: `frame-N` is minted, the frame is
  // appended (trimming beyond `max_frames`, which tombstones provenance) and
  // emitted as a frame record, completing at `at_ms`.
  CaptureResolution resolve(CaptureResultOutcome outcome,
                            const std::optional<CapturedFrame>& frame,
                            FrameTrigger trigger, int64_t at_ms,
                            int64_t max_frames, IdCounter* ids,
                            Session* session, Output* out);

  // `frame_id` when it is an available frame of the boundary's session that
  // completed at or after `boundary.at_ms` (and, when set, after its
  // sequence); otherwise nothing.
  OptString observed_after(const OptString& frame_id,
                           const ObservationBoundary& boundary) const;

 private:
  std::string accept(const CapturedFrame& frame, FrameTrigger trigger,
                     int64_t at_ms, int64_t max_frames, IdCounter* ids,
                     Session* session, Output* out);

  std::map<std::string, FrameProvenance> provenance_;
  OptString latest_frame_id_;
  int64_t sequence_ = 0;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_FRAME_LEDGER_H
