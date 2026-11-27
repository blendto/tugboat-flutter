// The bounds of the collector delivery queues and their one eviction rule
// (docs/stateful-engine.md section 7.5). Every queue is bounded by a
// `collector` setting and evicts the same way:
//
// | Queue          | Bound                       | When full                  |
// | -------------- | --------------------------- | -------------------------- |
// | Pending events | `maxPendingEvents` (60)     | drop oldest                |
// | Retry batches  | `maxPendingBatches` (20)    | drop oldest batch          |
// | Pending frames | `maxPendingFrames` (20)     | drop oldest; failed frames |
// |                |                             | are requeued at the front, |
// |                |                             | so they go first           |
//
// Fresh event batches hold at most `batchSize` (10) events and frame uploads
// at most `frameChunk` (20) frames. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DELIVERY_BOUNDS_H
#define TUGBOAT_SESSION_ENGINE_DELIVERY_BOUNDS_H

#include <cstddef>
#include <cstdint>
#include <deque>
#include <utility>
#include <vector>

namespace tugboat {
namespace engine {

// A configured count (validated in [1, 1000000]) as a queue size.
inline size_t bound(int64_t configured) {
  return static_cast<size_t>(configured);
}

// The eviction rule of every delivery queue: drops the oldest entries (the
// front) beyond `bound` and returns them, oldest first.
template <typename T>
std::vector<T> evict_oldest(std::deque<T>* queue, size_t bound) {
  std::vector<T> evicted;
  while (queue->size() > bound) {
    evicted.push_back(std::move(queue->front()));
    queue->pop_front();
  }
  return evicted;
}

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DELIVERY_BOUNDS_H
