#include "interaction_registry.h"

#include <utility>

namespace tugboat {
namespace engine {

namespace {

TransactionPtr found(const TransactionPtr* entry) {
  return entry == nullptr ? nullptr : *entry;
}

}  // namespace

TransactionPtr InteractionRegistry::pending_at(int64_t pointer) const {
  return found(pending_.find(pointer));
}

TransactionPtr InteractionRegistry::first_pending() const {
  return pending_.empty() ? nullptr : pending_.entries().front().second;
}

TransactionPtr InteractionRegistry::find(const std::string& id) const {
  const auto it = by_id_.find(id);
  return it == by_id_.end() ? nullptr : it->second;
}

bool InteractionRegistry::is_pending(const Transaction& tx) const {
  const TransactionPtr pending = pending_at(tx.pointer_id);
  return pending.get() == &tx;
}

void InteractionRegistry::add_pending(const TransactionPtr& tx) {
  tx->stage = TransactionStage::kPending;
  by_id_[tx->id()] = tx;
  pending_.put(tx->pointer_id, tx);
}

TransactionPtr InteractionRegistry::take_pending(int64_t pointer) {
  TransactionPtr tx = pending_at(pointer);
  pending_.erase(pointer);
  return tx;
}

void InteractionRegistry::release(const TransactionPtr& tx) {
  pending_.erase(tx->pointer_id);
  tx->stage = TransactionStage::kReleased;
  released_.put(tx->pointer_id, tx);
}

TransactionPtr InteractionRegistry::take_released(int64_t pointer) {
  TransactionPtr tx = found(released_.find(pointer));
  released_.erase(pointer);
  return tx;
}

std::vector<TransactionPtr> InteractionRegistry::take_all_released() {
  std::vector<TransactionPtr> out;
  for (const auto& entry : released_.entries()) out.push_back(entry.second);
  released_.clear();
  return out;
}

std::vector<int64_t> InteractionRegistry::pending_pointers() const {
  return pending_.keys();
}

void InteractionRegistry::forget(const std::string& id) { by_id_.erase(id); }

void InteractionRegistry::clear() {
  pending_.clear();
  released_.clear();
  by_id_.clear();
}

std::vector<TransactionPtr> InteractionRegistry::claimable(
    int64_t now_ms, const std::string& session_id) const {
  std::vector<TransactionPtr> out;
  for (const auto& entry : pending_.entries()) {
    const Transaction& tx = *entry.second;
    if (!skips_tap_settlement(tx.gesture) && tx.claimable() &&
        tx.origin.session_id == session_id) {
      out.push_back(entry.second);
    }
  }
  for (const auto& entry : released_.entries()) {
    const Transaction& tx = *entry.second;
    // Dart `isWithinReconciliationWindow`: the window compares fact time.
    const bool in_window =
        !tx.claim_deadline_ms || now_ms <= *tx.claim_deadline_ms;
    if (tx.claimable() && in_window && tx.origin.session_id == session_id) {
      out.push_back(entry.second);
    }
  }
  return out;
}

std::optional<int64_t> InteractionRegistry::earliest_claim_deadline() const {
  std::optional<int64_t> earliest;
  for (const auto& entry : released_.entries()) {
    const std::optional<int64_t>& deadline = entry.second->claim_deadline_ms;
    if (deadline && (!earliest || *deadline < *earliest)) earliest = deadline;
  }
  return earliest;
}

void InteractionRegistry::expire(TransactionPtr tx,
                                 std::vector<TransactionPtr>* out) {
  released_.erase(tx->pointer_id);
  if (tx->stage == TransactionStage::kReleased) {
    tx->stage = TransactionStage::kSettling;
  }
  out->push_back(std::move(tx));
}

std::vector<TransactionPtr> InteractionRegistry::sweep(int64_t now_ms,
                                                       int64_t grace_ms,
                                                       int64_t max_released) {
  std::vector<TransactionPtr> expired;
  std::vector<TransactionPtr> due;
  for (const auto& entry : released_.entries()) {
    const std::optional<int64_t>& deadline = entry.second->claim_deadline_ms;
    if (deadline && now_ms >= *deadline + grace_ms) due.push_back(entry.second);
  }
  for (const TransactionPtr& tx : due) expire(tx, &expired);
  while (static_cast<int64_t>(released_.size()) > max_released) {
    expire(released_.entries().front().second, &expired);
  }
  return expired;
}

}  // namespace engine
}  // namespace tugboat
