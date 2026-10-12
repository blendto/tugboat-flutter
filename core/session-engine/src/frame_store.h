// Frame provenance (Dart `_FrameProvenance`, `_hashToFrameId`,
// `_latestFrameId`, and the capturer's coalesce baselines): what each
// accepted frame of the session was captured for, which frame is the
// latest, the compatibility predicate that decides whether a frame may be
// attached to a request, and trim. Part of the capture seam
// (capture_seam.h). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_FRAME_STORE_H
#define TUGBOAT_SESSION_ENGINE_FRAME_STORE_H

#include <cstdint>
#include <map>
#include <optional>
#include <string>

#include "capture_types.h"
#include "frame_retention.h"
#include "models.h"
#include "output.h"
#include "session.h"

namespace tugboat {
namespace engine {

// Dart `_CaptureRequestContext`: the evidence fixed when a capture is
// requested. A frame is attachable only to requests of the same session,
// route epoch, route, navigator, route instance, and boundary generation.
struct RequestContext {
  std::string session_id;
  int64_t route_epoch = 0;
  OptString route;
  OptString navigator_id;
  OptString route_instance_id;
  int64_t boundary_generation = 0;
  // The capture boundary observed when the request was made.
  std::optional<BoundaryRect> boundary;
  FrameTrigger trigger = FrameTrigger::kManual;

  // Dart `compatibleWith`.
  bool compatible_with(const RequestContext& other) const;
  // Dart `surfaceCompatibleWith`: the same, except the boundary generation.
  bool surface_compatible_with(const RequestContext& other) const;
  // The `capture.request` `context` the host sees.
  CaptureContext effect_context() const;
};

// One accepted frame's provenance.
struct FrameProvenance {
  std::string frame_id;
  // The request context, with the frame's own boundary rect.
  RequestContext context;
  int64_t completed_at_ms = 0;
  int64_t sequence = 0;
  int64_t pixel_width = 0;
  int64_t pixel_height = 0;
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

class FrameStore {
 public:
  // Session start: forgets every frame and baseline.
  void reset();

  // Dart `_publishPhysicalCaptureResult`: mints `frame-N`, appends it to
  // `session` (trimming beyond `max_frames`), emits its frame record, and
  // makes it the latest frame. `context` is the request's, and the frame's
  // `boundaryRect` becomes its provenance boundary.
  // The session's reference to the frame's handle is retained, and that of
  // every trimmed frame released (`retention`).
  FrameRecord accept(const CapturedFrame& captured,
                     const RequestContext& context, int64_t at_ms,
                     int64_t max_frames, IdCounter* ids, Session* session,
                     FrameRetention* retention, Output* out);

  // Dart `_compatibleFrameFor`: the latest frame when it is available and
  // compatible with `context`, else nullptr.
  const FrameProvenance* compatible_latest(const RequestContext& context) const;
  // Dart `_surfaceCompatibleFrameFor`.
  const FrameProvenance* surface_compatible_latest(
      const RequestContext& context) const;
  // Dart `_isFrameCompatible`.
  bool is_compatible(const std::string& frame_id,
                     const RequestContext& context) const;
  // Dart `_reuseCompatibleFrame`: a compatible frame becomes the latest.
  OptString reuse(const std::string& frame_id, const RequestContext& context);
  // The retained frame with this content hash (Dart `_hashToFrameId`).
  OptString frame_with_content(const std::string& content_hash) const;
  // Dart `_latestFrameId != null`.
  bool has_latest() const { return latest_frame_id_.has_value(); }

  // The baseline offered to a capture that may coalesce, when both the
  // dHash and the structure of the accepted frame are known.
  std::optional<DHashBaseline> dhash_baseline() const;
  // Dart `commitAcceptedDHash` and `commitAcceptedStructure`.
  void commit_baselines(const CapturedFrame& captured);

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
  // Dart `_trim` for frames: tombstones, the content-hash index, the latest
  // frame, and `_trimFrameMetadata`.
  void trim(const std::string& dropped, const Session& session);
  void forget_unreferenced(const Session& session);

  std::map<std::string, FrameProvenance> provenance_;
  std::map<std::string, std::string> frame_by_content_;
  OptString latest_frame_id_;
  int64_t sequence_ = 0;
  OptString last_dhash_;
  OptString last_structure_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_FRAME_STORE_H
