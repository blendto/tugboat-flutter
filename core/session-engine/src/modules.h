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

// event.record, locale.set, identity.set.
void register_evidence_module(ModuleRegistry* registry);

// Collector delivery (docs/stateful-engine.md section 7).
void register_delivery_module(ModuleRegistry* registry);

// Interactions (section 9).
void register_interaction_module(ModuleRegistry* registry);

// Navigation (section 8.1).
void register_navigation_module(ModuleRegistry* registry);

// Capture coordination (section 8.2).
void register_capture_module(ModuleRegistry* registry);

// Deferred work after every command (coordination.h).
void register_coordination_module(ModuleRegistry* registry);

// A fresh registry holding every module. Tests extend a copy.
ModuleRegistry build_module_registry();

// The registry every engine handle uses, built once.
const ModuleRegistry& module_registry();

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_MODULES_H
