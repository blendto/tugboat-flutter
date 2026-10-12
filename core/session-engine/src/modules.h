// Every engine module's registration. Each module lives in its own
// `*_module.cpp`; `modules.cpp` registers all of them once.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_MODULES_H
#define TUGBOAT_SESSION_ENGINE_MODULES_H

#include "module_registry.h"

namespace tugboat {
namespace engine {

// fingerprint.identityParts, fingerprint.labelHash, collector.event,
// collector.sessionLifecycle.
void register_stateless_module(ModuleRegistry* registry);

// engine.configure, session.snapshot, timer.fired.
void register_engine_module(ModuleRegistry* registry);

// session.start, session.end, app.lifecycle.
void register_session_module(ModuleRegistry* registry);

// event.record, locale.set.
void register_evidence_module(ModuleRegistry* registry);

// identity.set, traits.set.
void register_identity_module(ModuleRegistry* registry);

// The session's references to accepted frames (section 7.6).
void register_frame_retention_module(ModuleRegistry* registry);

// Collector delivery (docs/stateful-engine.md section 7): transport.result,
// transport.flush.
void register_delivery_module(ModuleRegistry* registry);

// Interactions (section 9).
void register_interaction_module(ModuleRegistry* registry);

// Navigation and capture coordination (section 8).
void register_navigation_module(ModuleRegistry* registry);

// A fresh registry holding every module. Tests extend a copy.
ModuleRegistry build_module_registry();

// The registry every engine handle uses, built once.
const ModuleRegistry& module_registry();

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_MODULES_H
