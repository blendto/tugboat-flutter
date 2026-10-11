// Every module's message registration. A phase adds one function here and
// one line in `modules.cpp`; its handlers live in its own files.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_MODULES_H
#define TUGBOAT_SESSION_ENGINE_MODULES_H

#include "messages.h"

namespace tugboat {
namespace engine {

// fingerprint.identityParts, fingerprint.labelHash, collector.event,
// collector.sessionLifecycle (stateless_messages.cpp).
void register_stateless_messages(MessageRegistry* registry);

// engine.configure, session.snapshot, timer.fired (engine_messages.cpp).
void register_engine_messages(MessageRegistry* registry);

// session.start, session.end, app.lifecycle (session_messages.cpp).
void register_session_messages(MessageRegistry* registry);

// event.record, locale.set, identity.set (evidence_messages.cpp).
void register_evidence_messages(MessageRegistry* registry);

// The registry of every message type, built once.
const MessageRegistry& message_registry();

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_MODULES_H
