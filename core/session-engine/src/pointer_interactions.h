// The controller side of pointer input (Dart `recordPointerDown`,
// `recordPointerUp`, `recordPointerCancel`, `markPendingTapAsSwipe`,
// `markPendingClusterGesture`, `suppressPendingPointer`): it turns the
// pointer tracker's signals into interaction transactions and routes each
// completed gesture to its completion path. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_POINTER_INTERACTIONS_H
#define TUGBOAT_SESSION_ENGINE_POINTER_INTERACTIONS_H

#include "turn.h"
#include "pointer_tracker.h"

namespace tugboat {
namespace engine {

// Applies tracker signals in order. Pointer input is ignored while the app
// is in the background (Dart `_acceptsPointerInput`); the tracker itself
// keeps following contacts.
void apply_pointer_signals(Turn& turn,
                           const PointerSignals& signals);

// Teardown: abandons every pending pointer in pointer-down order. A tap
// becomes `cancelled`; swipe, scroll, pan, and zoom keep their gesture.
void abandon_pending_pointers(EngineState* state, Output* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_POINTER_INTERACTIONS_H
