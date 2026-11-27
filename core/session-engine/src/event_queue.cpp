#include "event_queue.h"

#include <utility>

#include "delivery_bounds.h"

namespace tugboat {
namespace engine {

size_t EventQueue::push(Value event, size_t bound) {
  pending_.push_back(std::move(event));
  return evict_oldest(&pending_, bound).size();
}

EventBatch EventQueue::take(size_t max) {
  EventBatch batch;
  while (!pending_.empty() && batch.size() < max) {
    batch.push_back(std::move(pending_.front()));
    pending_.pop_front();
  }
  return batch;
}

size_t EventQueue::push_retry(EventBatch batch, size_t bound) {
  retry_.push_back(std::move(batch));
  size_t evicted_events = 0;
  for (const EventBatch& evicted : evict_oldest(&retry_, bound)) {
    evicted_events += evicted.size();
  }
  return evicted_events;
}

size_t EventQueue::event_count() const {
  size_t count = pending_.size();
  for (const EventBatch& batch : retry_) {
    count += batch.size();
  }
  return count;
}

void EventQueue::clear() {
  pending_.clear();
  retry_.clear();
}

std::string stamp_event_batch(EventBatch* batch, const std::string& session_id,
                              const OptString& traits_id) {
  Value events = Value::array();
  for (Value& event : *batch) {
    event.set("sessionId", Value::string(session_id));
    if (traits_id && !traits_id->empty()) {
      event.set("traitsId", Value::string(*traits_id));
    }
    events.push(event);
  }
  Value body = Value::object();
  body.set("events", std::move(events));
  return encode_json(body);
}

}  // namespace engine
}  // namespace tugboat
