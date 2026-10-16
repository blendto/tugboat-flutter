// The interaction registry (Dart `InteractionRegistry`): pending
// transactions by pointer, released taps by pointer, and every unpublished
// transaction by id, each in insertion order. It also answers which
// transactions a navigation may claim and which released taps a sweep
// expires. It never publishes.
//
// A transaction's stage is the source of truth; the indexes are lookups by
// pointer and order. The registry moves the stage whenever it moves a
// transaction in or out of an index. Like Dart, a tap published while still
// in its claim window stays in the released index (and counts toward the
// cap) until the sweep removes it; its stage says it is published.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_REGISTRY_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_REGISTRY_H

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "interaction_transaction.h"
#include "ordered_map.h"

namespace tugboat {
namespace engine {

class InteractionRegistry {
 public:
  bool has_pending() const { return !pending_.empty(); }
  bool has_released() const { return !released_.empty(); }
  size_t released_count() const { return released_.size(); }

  TransactionPtr pending_at(int64_t pointer) const;
  // The earliest pending transaction still down (Dart: first in `pending`).
  TransactionPtr first_pending() const;
  // Unpublished transactions by interaction id (Dart `byId`).
  TransactionPtr find(const std::string& id) const;

  // Indexes a new pointer-down transaction (stage pending).
  void add_pending(const TransactionPtr& tx);
  // Removes the pending transaction of `pointer`, which moves to settling
  // until the caller moves it on (release, completion, or publication).
  TransactionPtr take_pending(int64_t pointer);
  // Moves a tap from pending to released (stage released).
  void release(const TransactionPtr& tx);
  // Removes released taps from the index; unpublished ones move to settling.
  TransactionPtr take_released(int64_t pointer);
  std::vector<TransactionPtr> take_all_released();
  // Pending pointers in pointer-down order.
  std::vector<int64_t> pending_pointers() const;
  // Drops the id index entry once the transaction is published or absorbed.
  void forget(const std::string& id);
  void clear();

  // Dart `eligibleForClaim`: pending transactions that are still taps, then
  // released taps inside their claim window at fact time `now_ms`, all from
  // session `session_id` and not yet claimed or published.
  std::vector<TransactionPtr> claimable(int64_t now_ms,
                                        const std::string& session_id) const;

  // The earliest claim deadline among released taps.
  std::optional<int64_t> earliest_claim_deadline() const;

  // Dart `_sweepReleasedInteractions`: expires released taps whose claim
  // deadline plus `grace_ms` has passed at `now_ms` (design section 5), then
  // the oldest beyond `max_released`. Expired taps leave the index and move
  // to settling (their tap settle still publishes them). Returns them.
  std::vector<TransactionPtr> sweep(int64_t now_ms, int64_t grace_ms,
                                    int64_t max_released);

 private:
  // Takes `tx` by value: it may live in the index it is erased from.
  void expire(TransactionPtr tx, std::vector<TransactionPtr>* out);

  OrderedMap<int64_t, TransactionPtr> pending_;
  OrderedMap<int64_t, TransactionPtr> released_;
  std::map<std::string, TransactionPtr> by_id_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_REGISTRY_H
