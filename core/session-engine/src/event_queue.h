// The collector events lane (docs/stateful-engine.md sections 7.2, 7.3, and
// 7.5): pending events mapped at record time, and the batches waiting to be
// retried. Reproduces `CollectorHttpSink`'s `_pendingEvents` and
// `_retryBatches`. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_EVENT_QUEUE_H
#define TUGBOAT_SESSION_ENGINE_EVENT_QUEUE_H

#include <cstddef>
#include <deque>
#include <string>
#include <vector>

#include "json.h"
#include "models.h"

namespace tugboat {
namespace engine {

// `/v1/events/batch` elements, mapped when recorded (with the record-time
// `userId`, without `sessionId` and `traitsId`).
using EventBatch = std::vector<Value>;

class EventQueue {
 public:
  // Appends a mapped event, then evicts the oldest beyond `bound`. Returns
  // how many were evicted.
  size_t push(Value event, size_t bound);
  size_t pending() const { return pending_.size(); }
  // Removes and returns up to `max` of the oldest pending events.
  EventBatch take(size_t max);

  // Appends a batch to retry later, then evicts the oldest batches beyond
  // `bound`. Returns how many events the evicted batches held.
  size_t push_retry(EventBatch batch, size_t bound);
  bool has_retry() const { return !retry_.empty(); }
  EventBatch& retry_head() { return retry_.front(); }
  size_t retry_head_size() const {
    return retry_.empty() ? 0 : retry_.front().size();
  }
  void pop_retry() { retry_.pop_front(); }

  bool empty() const { return pending_.empty() && retry_.empty(); }
  // Events waiting in either queue.
  size_t event_count() const;
  void clear();

 private:
  std::deque<Value> pending_;
  std::deque<EventBatch> retry_;
};

// Stamps every event in `batch` with the collector session id and a
// non-empty traits id when it is sent (Dart `_sendEventBatch`, section 7.2;
// a stamp replaces the earlier one in place, so a retried batch carries the
// ids current at its last send), then encodes `{"events": batch}`.
std::string stamp_event_batch(EventBatch* batch, const std::string& session_id,
                              const OptString& traits_id);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_EVENT_QUEUE_H
