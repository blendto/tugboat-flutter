// Publishing a transaction's one `interaction` event, and the terminal
// paths that publish it early (Dart `_publishCanonicalInteraction` and
// `_finalizeAbandonedTransaction`). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_PUBLISH_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_PUBLISH_H

#include "interaction_transaction.h"
#include "output.h"
#include "session.h"

namespace tugboat {
namespace engine {

struct EngineState;

// Records `tx`'s `interaction` event in `session` once; later calls do
// nothing. The transaction becomes published and leaves the id index.
void publish_interaction(EngineState* state, Session& session, Transaction& tx,
                         Output* out);

// Ends an unpublished transaction early (cancel of a released tap,
// abandonment, teardown): drops its scroll completion and publishes it. A
// tap becomes `cancelled`; swipe, scroll, pan, and zoom keep their gesture.
void finalize_abandoned(EngineState* state, Session& session, Transaction& tx,
                        Output* out);

// A secondary pointer joined another pointer's cluster gesture: it drops its
// scroll completion and leaves without an event (Dart
// `suppressPendingPointer`).
void absorb_interaction(EngineState* state, Transaction& tx, Output* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_PUBLISH_H
