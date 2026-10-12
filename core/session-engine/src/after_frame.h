// The temporal after-frame rules for interactions (Dart
// `_temporalAfterFrame` and `_temporalAfterFrameAfterCapture`): a frame is an
// interaction's after-frame only as an observation made after it. That
// claims nothing about what caused the frame. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_AFTER_FRAME_H
#define TUGBOAT_SESSION_ENGINE_AFTER_FRAME_H

#include "frame_ledger.h"
#include "interaction_transaction.h"
#include "models.h"
#include "session.h"

namespace tugboat {
namespace engine {

// `frame_id` when it belongs to `session`, completed no earlier than the
// release (or the pointer-down, before release), and is newer than the frame
// sequence at release.
OptString temporal_after_frame(const FrameLedger& ledger,
                               const Transaction& tx, const Session& session,
                               const OptString& frame_id);

// The after-capture fallback chain of a completed gesture: the fresh frame
// its own capture accepted when it is temporal, else the session's latest
// frame when it is. (Phase 3d adds route barrier frames between the two.)
OptString after_capture_frame(const FrameLedger& ledger, const Transaction& tx,
                              const Session& session,
                              const CaptureResolution& resolution);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_AFTER_FRAME_H
