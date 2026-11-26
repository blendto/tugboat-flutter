// One pointer gesture from pointer-down to its single published
// `interaction` event (Dart `InteractionOrigin` and `InteractionTransaction`
// in `interaction_transaction.dart`). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_TRANSACTION_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_TRANSACTION_H

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "interaction_types.h"
#include "models.h"
#include "tap_evidence.h"

namespace tugboat {
namespace engine {

// The visible route when the pointer went down (`current_route_stamp`,
// navigation_view.h).
struct RouteStamp {
  int64_t route_epoch = 0;
  OptString route;
  OptString navigator_id;
  OptString route_instance_id;
};

// Where the down point lies on the before-frame (Dart
// `TugboatCaptureCoordinate`, reduced to what the payload reads). Unavailable
// without a before-frame, without its boundary, or outside the boundary;
// positions are then omitted, never clamped.
struct CaptureCoordinate {
  bool available = false;
  double boundary_x = 0;
  double boundary_y = 0;
  double boundary_width = 0;
  double boundary_height = 0;
  double normalized_x = 0;
  double normalized_y = 0;
};

// Immutable pointer-down facts (Dart `InteractionOrigin`).
struct InteractionOrigin {
  std::string interaction_id;  // `event-N`, minted at pointer-down
  RouteStamp route;
  CaptureCoordinate coordinate;
  OptString before_frame;
  int64_t at_ms = 0;
  Point start_position;
  std::string session_id;
  std::optional<LocaleInfo> locale;  // the locale at pointer-down
};

// Where a transaction is in its life. Transitions only move forward:
//
//   pending ──up (tap)──► released ──claim window closes──► settling
//      │                     │                                 │
//      │ up (swipe, scroll,  │ cancel / abandon                │ settle,
//      │ pan, zoom)          ▼                                 │ capture
//      └───────────────► settling ────────────────────────► published
//
// Any non-terminal stage can also be published at once (cancel, abandon) or
// absorbed into another pointer's cluster gesture without an event. A tap
// that settles inside its claim window stays indexed as released (but no
// longer claimable) until the sweep removes it, as in Dart.
enum class TransactionStage {
  kPending,    // pointer down; indexed by pointer in the registry
  kReleased,   // a tap after pointer-up, inside its claim window
  kSettling,   // out of the registry, waiting for its after-frame
  kPublished,  // its `interaction` event was recorded (terminal)
  kAbsorbed,   // joined another pointer's gesture; never published (terminal)
};

// Scroll facts a pointer-linked scroll completion adds at publication.
struct ScrollFacts {
  double start_offset = 0;
  double end_offset = 0;
  int64_t overscroll_count = 0;
  std::optional<Anchor> anchor;
};

struct Transaction {
  Transaction(InteractionOrigin origin_in, int64_t pointer)
      : origin(std::move(origin_in)), pointer_id(pointer) {}

  const std::string& id() const { return origin.interaction_id; }
  bool terminal() const {
    return stage == TransactionStage::kPublished ||
           stage == TransactionStage::kAbsorbed;
  }
  // Dart `markSwipe`: a pan or zoom stays what it is.
  void mark_swipe();
  // Dart `markCluster`: only pan, zoom, and swipe classify a cluster.
  void mark_cluster(Gesture cluster_gesture, double cluster_scale,
                    int64_t cluster_pointer_count);
  // Dart `discardPreTapEvidence`.
  void discard_pre_tap_evidence();

  const InteractionOrigin origin;
  const int64_t pointer_id;
  TransactionStage stage = TransactionStage::kPending;
  Gesture gesture = Gesture::kTap;
  // Claimed as a navigation's cause (`claim_interaction_cause`).
  bool claimed = false;

  std::optional<int64_t> released_at_ms;
  std::optional<int64_t> released_frame_sequence;
  std::optional<int64_t> claim_deadline_ms;

  // Scroll starts linked while this pointer was down, in link order.
  std::vector<std::string> scroll_start_ids;
  std::optional<ScrollFacts> scroll;

  OptString after_frame;
  std::optional<Point> end_position;
  std::optional<double> scale;
  int64_t pointer_count = 1;

  // Pre-tap evidence from the primary `down` (exploration mode only).
  std::optional<TapEvidence> pre_tap_evidence;
  std::optional<TapFailureReason> failure_reason;
  // Resolved only once the gesture stays a tap.
  std::optional<Anchor> target_anchor;
};

using TransactionPtr = std::shared_ptr<Transaction>;

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_TRANSACTION_H
