// Collector delivery state (docs/stateful-engine.md section 7): lanes,
// queues, the flush cursor, and in-flight requests. Owned by the delivery
// module (delivery_module.cpp). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DELIVERY_STATE_H
#define TUGBOAT_SESSION_ENGINE_DELIVERY_STATE_H

namespace tugboat {
namespace engine {

struct DeliveryState {};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DELIVERY_STATE_H
