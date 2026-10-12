// Scroll evidence (Dart `recordScrollStart` … `recordScrollEnd`): a tracker
// per scrollable, scroll samples, and the completion of a pointer-linked
// scroll. Pointer-up and scroll-end can arrive in either order; the scroll
// interaction publishes once both have arrived and the scroll-end capture
// has resolved. A scroll that no pointer owned (programmatic) records only
// samples. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_SCROLL_INTERACTIONS_H
#define TUGBOAT_SESSION_ENGINE_SCROLL_INTERACTIONS_H

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "capture_seam.h"
#include "interaction_facts.h"
#include "interaction_transaction.h"
#include "interaction_turn.h"
#include "ordered_map.h"

namespace tugboat {
namespace engine {

// Timer ids are `interaction.scrollEnd.<scroll start id>`.
constexpr char kScrollEndTimerPrefix[] = "interaction.scrollEnd.";

// One scrollable between scroll start and scroll end (Dart `_ScrollTracker`).
struct ScrollTracker {
  std::string start_id;  // `event-N`, minted at scroll start
  double start_offset = 0;
  OptString before_frame;
  std::optional<Anchor> anchor;
  bool pointer_linked = false;
  int64_t overscroll_count = 0;
  std::optional<int64_t> last_sample_mono_us;
};

// A pointer-linked scroll that ended (Dart `_PendingScrollCompletion`).
//
//   delaying ──timer──► capturing ──result──► resolved ──pointer-up──► gone
//       │                   │
//       │ new pointer       │ its pointer cancelled: the capture still
//       │ or scroll         ▼ updates the last sample, then it is gone
//       └──► resolved    discarded
struct ScrollCompletion {
  enum class Stage { kDelaying, kCapturing, kResolved, kDiscarded };
  Stage stage = Stage::kDelaying;
  ScrollFacts facts;
  // None when the completion resolved before its capture (superseded).
  std::optional<CaptureResolution> resolution;
};

struct ScrollState {
  std::map<std::string, ScrollTracker> trackers;  // by scrollable id
  OrderedMap<std::string, ScrollCompletion> completions;  // by start id
  // Pointer-up'd scroll interactions waiting for their completion.
  OrderedMap<std::string, TransactionPtr> interactions;  // by start id
};

void record_scroll(InteractionTurn& turn, const ScrollFact& fact);

// Links a scroll start to the earliest pending pointer (Dart
// `_linkScrollStartToActiveGestures`). Returns whether one owned it.
bool link_scroll_start(EngineState* state, const std::string& start_id);

// A new pointer or scroll makes waiting scroll-end delays stale: their
// completions resolve without a frame. Returns their start ids, to publish
// once the caller's own work is done (Dart publishes them in a microtask).
std::vector<std::string> cancel_scroll_end_delays(EngineState* state,
                                                  Output* out);

// Publishes the scroll interaction of `start_id` when its pointer is up and
// its completion resolved (Dart `_publishResolvedScrollInteraction`).
void publish_resolved_scroll(EngineState* state, Session& session,
                             const std::string& start_id, Output* out);

// A pointer-up'd scroll interaction joins its completion.
void attach_scroll_interaction(EngineState* state, Session& session,
                               const std::string& start_id,
                               const TransactionPtr& tx, Output* out);

void advance_scroll_end(InteractionTurn& turn, const std::string& start_id);
void finish_scroll_end(InteractionTurn& turn, const std::string& start_id,
                       const CaptureResolution& resolution);

// Drops every scroll completion `tx` owns (Dart
// `_discardScrollCompletionFor`).
void discard_scroll_completion(EngineState* state, const Transaction& tx,
                               Output* out);

// Teardown: finalizes waiting scroll interactions (keeping `scroll`), then
// forgets every tracker and completion.
void finalize_scroll_interactions(EngineState* state, Output* out);
void clear_scroll_state(EngineState* state, Output* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_SCROLL_INTERACTIONS_H
