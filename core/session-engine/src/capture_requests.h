// The interaction module's outstanding `capture.request` effects and who
// waits for each answer (principle 4: answers to unknown or stale request
// ids are ignored). Phase 3d's capture scheduler replaces this; it issues
// requests one by one and implements no coalescing, budget, or dedupe.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_REQUESTS_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_REQUESTS_H

#include <cstdint>
#include <map>
#include <optional>
#include <string>

#include "models.h"
#include "output.h"
#include "session.h"

namespace tugboat {
namespace engine {

// Who consumes a capture answer. `key` is the interaction id (tap settle,
// gesture), the scroll start id (scroll end), or the event id (focus or
// system-input observation).
struct CaptureOwner {
  enum class Kind { kTapSettle, kGesture, kScrollEnd, kObservation };
  Kind kind = Kind::kGesture;
  std::string key;
};

// What to ask the host for.
struct CaptureAsk {
  FrameTrigger trigger = FrameTrigger::kInteraction;
  bool force = false;
  bool require_fresh_paint = false;
  int64_t not_before_mono_us = 0;
  CaptureContext context;
};

// A completed gesture asks for a fresh `interaction` frame now (Dart:
// `trigger: interaction, force: true, settleDelay: zero`).
CaptureAsk interaction_capture(int64_t now_mono_us, CaptureContext context);

class CaptureRequests {
 public:
  // Mints `capture_request-N`, emits `capture.request`, and remembers the
  // owner. Returns the request id.
  std::string issue(const CaptureOwner& owner, const CaptureAsk& ask,
                    IdCounter* ids, Output* out);

  struct Pending {
    CaptureOwner owner;
    FrameTrigger trigger;
  };
  // Forgets and returns the request, or nothing for an unknown id.
  std::optional<Pending> take(const std::string& request_id);

  // Invalidates every outstanding request (teardown); late answers are then
  // ignored.
  void clear() { pending_.clear(); }

 private:
  std::map<std::string, Pending> pending_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_REQUESTS_H
