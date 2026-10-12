#include "scroll_interactions.h"

#include <algorithm>
#include <utility>

#include "after_frame.h"
#include "capture_requests.h"
#include "engine_state.h"
#include "interaction_claims.h"
#include "interaction_publish.h"

namespace tugboat {
namespace engine {

namespace {

std::string timer_id(const std::string& start_id) {
  return kScrollEndTimerPrefix + start_id;
}

ScrollSample make_sample(const InteractionTurn& turn, const ScrollFact& fact,
                         const ScrollTracker& tracker) {
  ScrollSample sample;
  sample.at_ms = turn.now_ms();
  sample.offset = fact.offset;
  sample.before_frame = tracker.before_frame;
  if (tracker.anchor) {
    sample.scrollable_fingerprint = tracker.anchor->fingerprint;
  }
  sample.axis = std::string(scroll_axis_name(fact.axis));
  if (fact.max_scroll_extent && *fact.max_scroll_extent > 0) {
    sample.offset_norm = fact.offset / *fact.max_scroll_extent;
  }
  return sample;
}

void append_sample(InteractionTurn& turn, ScrollSample sample) {
  turn.session->append_scroll_sample(
      std::move(sample), turn.state->config.limits.max_scroll_samples);
}

void publish_all(EngineState* state, Session& session,
                 const std::vector<std::string>& start_ids, Output* out) {
  for (const std::string& start_id : start_ids) {
    publish_resolved_scroll(state, session, start_id, out);
  }
}

void start_scroll(InteractionTurn& turn, const ScrollFact& fact) {
  EngineState& state = *turn.state;
  // A new scroll means the viewport is no longer idle.
  const std::vector<std::string> stale =
      cancel_scroll_end_delays(&state, turn.out);
  ScrollState& scrolls = state.interactions.scrolls;
  if (scrolls.trackers.count(fact.scrollable_id) == 0) {
    ScrollTracker tracker;
    const FrameProvenance* before = state.frames.latest(turn.session->id());
    if (before != nullptr) tracker.before_frame = before->frame_id;
    tracker.start_id = state.ids.next("event");
    tracker.start_offset = fact.offset;
    tracker.anchor = fact.anchor;
    if (state.config.interaction.capture_scroll_samples) {
      // The start sample does not start the update cadence, as in Dart.
      append_sample(turn, make_sample(turn, fact, tracker));
    }
    tracker.pointer_linked = link_scroll_start(&state, tracker.start_id);
    scrolls.trackers[fact.scrollable_id] = std::move(tracker);
  }
  publish_all(&state, *turn.session, stale, turn.out);
}

void update_scroll(InteractionTurn& turn, const ScrollFact& fact) {
  EngineState& state = *turn.state;
  const auto it = state.interactions.scrolls.trackers.find(fact.scrollable_id);
  if (it == state.interactions.scrolls.trackers.end()) return;
  ScrollTracker& tracker = it->second;
  const InteractionConfig& config = state.config.interaction;
  // Change C1: the sample cadence uses the monotonic clock.
  const bool due = !tracker.last_sample_mono_us ||
                   turn.at.mono_us - *tracker.last_sample_mono_us >=
                       config.scroll_capture_interval_ms * 1000;
  if (!config.capture_scroll_samples || !due) return;
  tracker.last_sample_mono_us = turn.at.mono_us;
  append_sample(turn, make_sample(turn, fact, tracker));
}

void request_capture(InteractionTurn& turn, const std::string& start_id,
                     ScrollCompletion& completion) {
  EngineState& state = *turn.state;
  completion.stage = ScrollCompletion::Stage::kCapturing;
  state.interactions.captures.issue(
      {CaptureOwner::Kind::kScrollEnd, start_id},
      interaction_capture(turn.at.mono_us, current_capture_context(state)),
      &state.ids, turn.out);
}

void end_scroll(InteractionTurn& turn, const ScrollFact& fact) {
  EngineState& state = *turn.state;
  ScrollState& scrolls = state.interactions.scrolls;
  const auto it = scrolls.trackers.find(fact.scrollable_id);
  if (it == scrolls.trackers.end()) return;
  const ScrollTracker tracker = it->second;
  scrolls.trackers.erase(it);
  // A programmatic scroll keeps its samples but makes no interaction.
  if (!tracker.pointer_linked) return;
  ScrollCompletion completion;
  completion.facts.start_offset = tracker.start_offset;
  completion.facts.end_offset = fact.offset;
  completion.facts.overscroll_count = tracker.overscroll_count;
  completion.facts.anchor = tracker.anchor;
  scrolls.completions.put(tracker.start_id, std::move(completion));
  ScrollCompletion& stored = *scrolls.completions.find(tracker.start_id);
  const int64_t delay_ms = state.config.interaction.scroll_end_capture_delay_ms;
  if (delay_ms > 0) {
    state.timers.schedule(timer_id(tracker.start_id),
                          turn.at.mono_us + delay_ms * 1000, turn.out);
    return;
  }
  request_capture(turn, tracker.start_id, stored);
}

}  // namespace

void record_scroll(InteractionTurn& turn, const ScrollFact& fact) {
  switch (fact.phase) {
    case ScrollPhase::kStart:
      start_scroll(turn, fact);
      break;
    case ScrollPhase::kUpdate:
      update_scroll(turn, fact);
      break;
    case ScrollPhase::kOverscroll: {
      auto& trackers = turn.state->interactions.scrolls.trackers;
      const auto it = trackers.find(fact.scrollable_id);
      if (it != trackers.end()) ++it->second.overscroll_count;
      break;
    }
    case ScrollPhase::kEnd:
      end_scroll(turn, fact);
      break;
  }
}

bool link_scroll_start(EngineState* state, const std::string& start_id) {
  // A scroll notification names no pointer: give it one stable owner. The
  // owner may still be a tap (change C12 publishes it as a scroll).
  const TransactionPtr owner = state->interactions.registry.first_pending();
  if (owner == nullptr) return false;
  std::vector<std::string>& ids = owner->scroll_start_ids;
  if (std::find(ids.begin(), ids.end(), start_id) == ids.end()) {
    ids.push_back(start_id);
  }
  return true;
}

std::vector<std::string> cancel_scroll_end_delays(EngineState* state,
                                                  Output* out) {
  std::vector<std::string> resolved;
  for (auto& entry : state->interactions.scrolls.completions.entries()) {
    ScrollCompletion& completion = entry.second;
    if (completion.stage != ScrollCompletion::Stage::kDelaying) continue;
    state->timers.cancel(timer_id(entry.first), out);
    completion.stage = ScrollCompletion::Stage::kResolved;
    resolved.push_back(entry.first);
  }
  return resolved;
}

void publish_resolved_scroll(EngineState* state, Session& session,
                             const std::string& start_id, Output* out) {
  ScrollState& scrolls = state->interactions.scrolls;
  const ScrollCompletion* completion = scrolls.completions.find(start_id);
  const TransactionPtr* found = scrolls.interactions.find(start_id);
  if (completion == nullptr || found == nullptr ||
      completion->stage != ScrollCompletion::Stage::kResolved) {
    return;
  }
  const TransactionPtr tx = *found;
  // The final scroll facts do not depend on the capture.
  tx->scroll = completion->facts;
  tx->after_frame =
      completion->resolution
          ? after_capture_frame(state->frames, *tx, session,
                                *completion->resolution)
          : std::nullopt;
  scrolls.interactions.erase(start_id);
  scrolls.completions.erase(start_id);
  publish_interaction(state, session, *tx, out);
}

void attach_scroll_interaction(EngineState* state, Session& session,
                               const std::string& start_id,
                               const TransactionPtr& tx, Output* out) {
  tx->stage = TransactionStage::kSettling;
  state->interactions.scrolls.interactions.put(start_id, tx);
  publish_resolved_scroll(state, session, start_id, out);
}

void advance_scroll_end(InteractionTurn& turn, const std::string& start_id) {
  ScrollCompletion* completion =
      turn.state->interactions.scrolls.completions.find(start_id);
  if (completion == nullptr ||
      completion->stage != ScrollCompletion::Stage::kDelaying) {
    return;
  }
  // (Phase 3d: a route change since the scroll started takes Dart's
  // superseded path here.)
  request_capture(turn, start_id, *completion);
}

void finish_scroll_end(InteractionTurn& turn, const std::string& start_id,
                       const CaptureResolution& resolution) {
  EngineState& state = *turn.state;
  ScrollState& scrolls = state.interactions.scrolls;
  ScrollCompletion* completion = scrolls.completions.find(start_id);
  if (completion == nullptr) return;
  if (state.config.interaction.capture_scroll_samples) {
    if (ScrollSample* last = turn.session->last_scroll_sample()) {
      last->offset = completion->facts.end_offset;
      last->after_frame = resolution.outcome == CaptureOutcome::kFreshAccepted
                              ? resolution.frame_id
                              : std::nullopt;
    }
  }
  if (completion->stage == ScrollCompletion::Stage::kDiscarded) {
    scrolls.completions.erase(start_id);
    return;
  }
  completion->stage = ScrollCompletion::Stage::kResolved;
  completion->resolution = resolution;
  publish_resolved_scroll(&state, *turn.session, start_id, turn.out);
}

void discard_scroll_completion(EngineState* state, const Transaction& tx,
                               Output* out) {
  ScrollState& scrolls = state->interactions.scrolls;
  for (const std::string& start_id : tx.scroll_start_ids) {
    if (ScrollCompletion* completion = scrolls.completions.find(start_id)) {
      switch (completion->stage) {
        case ScrollCompletion::Stage::kDelaying:
          state->timers.cancel(timer_id(start_id), out);
          scrolls.completions.erase(start_id);
          break;
        case ScrollCompletion::Stage::kCapturing:
          completion->stage = ScrollCompletion::Stage::kDiscarded;
          break;
        case ScrollCompletion::Stage::kResolved:
          scrolls.completions.erase(start_id);
          break;
        case ScrollCompletion::Stage::kDiscarded:
          break;
      }
    }
    scrolls.interactions.erase(start_id);
    for (auto& entry : scrolls.trackers) {
      if (entry.second.start_id == start_id) {
        entry.second.pointer_linked = false;
      }
    }
  }
}

void finalize_scroll_interactions(EngineState* state, Output* out) {
  Session* session = state->live_session();
  if (session == nullptr) return;
  std::vector<TransactionPtr> waiting;
  for (const auto& entry : state->interactions.scrolls.interactions.entries()) {
    waiting.push_back(entry.second);
  }
  for (const TransactionPtr& tx : waiting) {
    finalize_abandoned(state, *session, *tx, out);
  }
}

void clear_scroll_state(EngineState* state, Output* out) {
  ScrollState& scrolls = state->interactions.scrolls;
  for (const auto& entry : scrolls.completions.entries()) {
    if (entry.second.stage == ScrollCompletion::Stage::kDelaying) {
      state->timers.cancel(timer_id(entry.first), out);
    }
  }
  scrolls.trackers.clear();
  scrolls.completions.clear();
  scrolls.interactions.clear();
}

}  // namespace engine
}  // namespace tugboat
