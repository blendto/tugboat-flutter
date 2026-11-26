// The keys a host's durable outbox stores each `http.send` under
// (docs/stateful-engine.md section 3.1), so hosts no longer parse request
// bodies to derive them. Each key names one unit the collector answers for:
// a lifecycle post, an event batch, or one frame of an upload. The formats
// are the ones both native hosts' outboxes already persist, so entries
// written before the engine carried keys keep matching. Not part of the C
// ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DELIVERY_KEYS_H
#define TUGBOAT_SESSION_ENGINE_DELIVERY_KEYS_H

#include <cstdint>
#include <string>

#include "event_queue.h"

namespace tugboat {
namespace engine {

// `<sessionId>/l/<eventType>/<triggeredAt>`: the body's `sessionId`,
// `eventType`, and `triggeredAt` (fixed when the post was queued).
std::string lifecycle_delivery_key(const std::string& session_id,
                                   const std::string& event_type,
                                   const std::string& triggered_at);

// `<sessionId>/e/<digest>`: `digest` is the first 16 lowercase hex digits of
// SHA-256 over the batch's event `id`s, sorted by UTF-16 code unit and
// joined by `\n`. A retried batch carries the same events, so the same key.
std::string event_batch_delivery_key(const std::string& session_id,
                                     const EventBatch& batch);

// `<sessionId>/f/<frameNo>`: one frame of a `/v1/frames` upload.
std::string frame_delivery_key(const std::string& session_id,
                               int64_t frame_no);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DELIVERY_KEYS_H
