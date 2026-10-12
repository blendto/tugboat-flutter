// The canonical `interaction` event (interaction schema 2): the envelope and
// payload rules of Dart `buildInteractionV2Payload` and the coordinate rules
// of `coordinate_space.dart`. Pure functions of a transaction.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_PAYLOAD_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_PAYLOAD_H

#include "frame_ledger.h"
#include "interaction_transaction.h"
#include "json.h"
#include "models.h"

namespace tugboat {
namespace engine {

// `interactionSchema` (Dart `tugboatInteractionSchemaVersion`).
constexpr int64_t kInteractionSchemaVersion = 2;

// Where `position` lies on `before_frame` (nullptr: no before-frame). It is
// available only with a frame of known pixel size and boundary, and only
// inside that boundary (Dart `buildCaptureCoordinate`).
CaptureCoordinate sample_coordinate(Point position,
                                    const FrameProvenance* before_frame);

// The event `data` (Dart `buildInteractionV2Payload`):
// - `interactionSchema`, `gesture`, `route`, `targetFingerprint`, and for a
//   tap `fingerprintConfidence` (pre-tap evidence only) or
//   `targetResolutionFailureReason`;
// - `payload` unless the gesture is `cancelled`: `position` only with an
//   available coordinate; `endPosition`, `delta`, `pointerCount`, `scale`
//   for swipe, pan, and zoom; offsets and `overscrollCount` for scroll.
Value interaction_data(const Transaction& tx);

// The `interaction` event for `tx`: minted at pointer-down (id, `atMs`,
// before-frame, locale), published now (after-frame, anchor, data).
Event interaction_event(const Transaction& tx);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_PAYLOAD_H
