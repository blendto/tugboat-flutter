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

#include "capture_types.h"
#include "interaction_facts.h"
#include "interaction_publish.h"
#include "interaction_transaction.h"
#include "turn.h"
#include "ordered_map.h"
#include "route_work.h"

namespace tugboat {
namespace engine {

// Timer ids are `interaction.scrollEnd.<scroll start id>`.
constexpr char kScrollEndTimerPrefix[] = "interaction.scrollEnd.";

// One scrollable between scroll start and scroll end (Dart `_ScrollTracker`).
struct ScrollTracker {
  std::string start_id;  // `event-N`, minted at scroll start
  int64_t route_epoch = 0;
  double start_offset = 0;
  OptString before_frame;
  std::optional<Anchor> anchor;
  bool pointer_linked = false;
  int64_t overscroll_count = 0;
  std::optional<int64_t> last_sample_mono_us;
  std::optional<int64_t> last_screenshot_mono_us;
};

// A pointer-linked scroll that ended (Dart `_PendingScrollCompletion`).
//
//   delaying ──timer──► capturing ──result──► resolved ──pointer-up──►
//       │                   │                     walking ──► published
//       │ new pointer       │ its pointer cancelled: the capture still
//       │ or scroll         ▼ updates the last sample, then it is gone
//       └──► resolved    discarded
//
// Walking is the after-capture fallback chain (route barriers).
struct ScrollCompletion {
  enum class Stage { kDelaying, kCapturing, kResolved, kWalking, kDiscarded };
  Stage stage = Stage::kDelaying;
  ScrollFacts facts;
  // The route epoch at scroll start. A navigation since then supersedes
  // the scroll's capture: it is still made, but updates no sample.
  int64_t route_epoch = 0;
  bool superseded = false;
  // None when the completion resolved before its capture (superseded).
  std::optional<CaptureResolution> resolution;
  AfterCaptureWalk walk;
};

struct ScrollState {
  std::map<std::string, ScrollTracker> trackers;  // by scrollable id
  OrderedMap<std::string, ScrollCompletion> completions;  // by start id
  // Pointer-up'd scroll interactions waiting for their completion.
  OrderedMap<std::string, TransactionPtr> interactions;  // by start id
};

void record_scroll(Turn& turn, const ScrollFact& fact);

// Links a scroll start to the earliest pending pointer (Dart
// `_linkScrollStartToActiveGestures`). Returns whether one owned it.
bool link_scroll_start(EngineState* state, const std::string& start_id);

// A new pointer or scroll makes waiting scroll-end delays stale: their
// completions resolve without a frame. Returns their start ids, to publish
// once the caller's own work is done (Dart publishes them in a microtask).
std::vector<std::string> cancel_scroll_end_delays(EngineState* state,
                                                  Output* out);

// Publishes the scroll interaction of `start_id` when its pointer is up and
// its completion resolved (Dart `_publishResolvedScrollInteraction`): with
// a capture, after its after-capture walk; without one, without a frame.
void publish_resolved_scroll(Turn& turn, const std::string& start_id);

// A pointer-up'd scroll interaction joins its completion.
void attach_scroll_interaction(Turn& turn, const std::string& start_id,
                               const TransactionPtr& tx);

void advance_scroll_end(Turn& turn, const std::string& start_id);
void finish_scroll_end(Turn& turn, const std::string& start_id,
                       const CaptureResolution& resolution);
// A route barrier the scroll's after-capture walk waits on is done.
void scroll_route_barrier_done(Turn& turn, const std::string& start_id,
                               const RouteWork& barrier);

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
