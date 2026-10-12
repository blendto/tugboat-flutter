// Interaction state (docs/stateful-engine.md section 9): pointer contacts,
// the interaction registry, tap settles, completing gestures, scroll
// trackers, deferred input observations, and the module's outstanding
// capture requests. Owned by the interaction module (interaction_module.cpp).
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_STATE_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_STATE_H

#include <set>
#include <string>

#include "capture_requests.h"
#include "gesture_completion.h"
#include "input_observations.h"
#include "interaction_registry.h"
#include "pointer_tracker.h"
#include "scroll_interactions.h"
#include "tap_settle.h"

namespace tugboat {
namespace engine {

struct InteractionState {
  PointerTracker pointers;
  InteractionRegistry registry;
  TapSettles settles;
  GestureCaptures gestures;
  ScrollState scrolls;
  InputObservations observations;
  CaptureRequests captures;
  // Tap inventories already recorded this session (`routeKey|hash|`).
  std::set<std::string> emitted_inventories;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_STATE_H
