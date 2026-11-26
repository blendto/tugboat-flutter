// Collector delivery (docs/stateful-engine.md section 7): what the rest of
// the engine tells delivery. Delivery decides what to send, when, and what
// each response means; the host performs the requests (`http.send`) and
// answers with `transport.result`. It replaces `CollectorHttpSink`'s policy.
//
// Implementation:
// - delivery.cpp         phases, triggers, timers, identity, session end,
//                        reset and dispose
// - flush_pass.cpp       the flush pass cursor and response handling
// - delivery_lanes.cpp   queueing events and frames, gaps, frame release
// - lifecycle_lane, event_queue, frame_lane, delivery_gaps,
//   delivery_bounds, transport: the parts, as plain types.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DELIVERY_H
#define TUGBOAT_SESSION_ENGINE_DELIVERY_H

#include <string>

#include "clock.h"
#include "engine_state.h"
#include "json.h"
#include "models.h"
#include "module_registry.h"
#include "output.h"
#include "transport.h"

namespace tugboat {
namespace engine {

// Lifecycle hooks (module_registry.h).
void delivery_session_started(const At& at, EngineState* state, Output* out);
void delivery_backgrounded(const At& at, EngineState* state, Output* out);
void delivery_foregrounded(const At& at, EngineState* state, Output* out);
void delivery_session_ending(const At& at, EngineState* state, Output* out);

// Event record observer: queues the event for `/v1/events/batch`; the
// `batchSize`-th pending event triggers a pass.
void delivery_event_recorded(const EventRecord& record, const At& at,
                             EngineState* state, Output* out);

// Frame acceptance observer: queues the frame for `/v1/frames` and takes
// delivery's reference to it while delivery is active.
void delivery_frame_accepted(const Frame& frame, const std::string& handle,
                             EngineState* state, Output* out);

// `timer.fired` for a `delivery.` timer.
void delivery_timer_fired(const std::string& timer_id, const At& at,
                          EngineState* state, Output* out);

// `transport.result`.
void delivery_transport_result(const TransportResult& result, const At& at,
                               EngineState* state, Output* out);

// `transport.flush`: run a flush pass now (for example before exit).
void delivery_flush_requested(const At& at, EngineState* state, Output* out);

// The runtime user id changed (`identity.set`).
void delivery_user_changed(const At& at, EngineState* state, Output* out);

// The traits bag changed (`traits.set`, identity_module.cpp).
void delivery_traits_changed(const At& at, EngineState* state, Output* out);

// `engine.dispose`: reports unconfirmed work once, then discards delivery
// and releases every frame it still references.
void delivery_dispose(const At& at, EngineState* state, Output* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DELIVERY_H
