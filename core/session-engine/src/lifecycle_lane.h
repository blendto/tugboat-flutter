// The collector lifecycle lane (docs/stateful-engine.md section 7.1): a
// strict FIFO of `/v1/sessions` posts, the identity debounce that feeds it,
// and the handshake that reads the collector session id and traits id from
// accepted responses. Reproduces
// `CollectorHttpSink`'s `_pendingLifecycle` and `_applyLifecycleResponse`.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_LIFECYCLE_LANE_H
#define TUGBOAT_SESSION_ENGINE_LIFECYCLE_LANE_H

#include <cstdint>
#include <deque>
#include <optional>
#include <string>

#include "clock.h"
#include "models.h"

namespace tugboat {
namespace engine {

// TugboatCollectorSessionEventType.
enum class LifecycleKind {
  kSessionStart,
  kSessionIdentify,
  kTraitsUpdated,
  kUserChanged,
  kSessionEnd,
};

const char* lifecycle_kind_name(LifecycleKind kind);

// One queued post. Its body is built when it is sent, from the identity at
// that moment; `triggered` (when the entry was queued) is fixed.
struct LifecycleEntry {
  uint64_t seq = 0;  // identity of the entry while it waits in the lane
  LifecycleKind kind = LifecycleKind::kSessionStart;
  At triggered;  // wall: `triggeredAt`; mono: `atMs` (change C1)
  // `session_start` only: the session's locale when it was queued.
  std::optional<LocaleInfo> active_locale;
};

// Only the head is ever in flight, and it leaves the lane only when the
// collector accepts it (any other outcome keeps it at the head).
class LifecycleLane {
 public:
  void push(LifecycleKind kind, const At& triggered,
            std::optional<LocaleInfo> active_locale);
  bool empty() const { return entries_.empty(); }
  size_t size() const { return entries_.size(); }
  const LifecycleEntry& head() const { return entries_.front(); }
  void pop() { entries_.pop_front(); }
  void clear() { entries_.clear(); }
  // Dart `_isSessionStartPending`.
  bool has_session_start() const;

 private:
  std::deque<LifecycleEntry> entries_;
  uint64_t next_seq_ = 0;
};

// The coalesced identity post: which lifecycle event and when it was
// triggered.
struct IdentityPost {
  LifecycleKind kind = LifecycleKind::kUserChanged;
  At triggered;
};

// The identity debounce (section 7.1): user id and traits changes wait out
// `identityDebounceMs` after the last change and merge into one lifecycle
// post, `session_identify` when both changed (Dart's dirty flags and
// `_enqueueCoalescedIdentityUpdate`). The delivery module arms the timer.
class IdentityDebounce {
 public:
  void mark_user_changed(const At& at) { user_at_ = at; }
  void mark_traits_changed(const At& at) { traits_at_ = at; }
  bool dirty() const { return user_at_ || traits_at_; }
  // The coalesced post, or nothing when clean; clears both changes. With
  // both dirty it is `session_identify` at the later change (the traits
  // change on a tie, as Dart's `isAfter` picks it).
  std::optional<IdentityPost> take();
  void reset() {
    user_at_.reset();
    traits_at_.reset();
  }

 private:
  std::optional<At> user_at_;
  std::optional<At> traits_at_;
};

// The collector ids an accepted lifecycle response updates.
struct CollectorIds {
  OptString session_id;  // per session; set by an accepted session_start
  OptString traits_id;   // survives sessions
};

// Dart `_applyLifecycleResponse` for an accepted post of `kind`. A
// `session_start` takes `sessionId` from the body, and falls back to
// `local_session_id` when the body is empty, not a JSON object, or carries
// an empty or missing `sessionId`. Any accepted response caches a non-empty
// `traitsId`. A wrongly typed field abandons the rest of the body, as Dart's
// failed cast does.
void apply_lifecycle_response(LifecycleKind kind, const std::string& body,
                              const std::string& local_session_id,
                              CollectorIds* ids);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_LIFECYCLE_LANE_H
