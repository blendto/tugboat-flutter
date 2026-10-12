#include "after_frame.h"

#include <optional>

namespace tugboat {
namespace engine {

OptString temporal_after_frame(const FrameLedger& ledger,
                               const Transaction& tx, const Session& session,
                               const OptString& frame_id) {
  ObservationBoundary boundary;
  boundary.session_id = session.id();
  boundary.at_ms = tx.released_at_ms.value_or(tx.origin.at_ms);
  boundary.after_sequence = tx.released_frame_sequence;
  return ledger.observed_after(frame_id, boundary);
}

OptString after_capture_frame(const FrameLedger& ledger, const Transaction& tx,
                              const Session& session,
                              const CaptureResolution& resolution) {
  const OptString captured =
      temporal_after_frame(ledger, tx, session, resolution.frame_id);
  if (resolution.outcome == CaptureOutcome::kFreshAccepted && captured) {
    return captured;
  }
  const FrameProvenance* latest = ledger.latest(session.id());
  return temporal_after_frame(
      ledger, tx, session,
      latest == nullptr ? std::nullopt : OptString(latest->frame_id));
}

}  // namespace engine
}  // namespace tugboat
