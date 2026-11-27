// A map that iterates in insertion order, like a Dart `LinkedHashMap`.
// The interaction logic depends on that order (the first pending pointer
// owns a scroll start, the oldest released transaction is evicted first,
// abandonment publishes in pointer-down order), so it cannot use `std::map`
// alone. Lookup, insertion, and removal are logarithmic, so a host that never
// answers its capture requests cannot make the engine quadratic.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ORDERED_MAP_H
#define TUGBOAT_SESSION_ENGINE_ORDERED_MAP_H

#include <cstddef>
#include <iterator>
#include <list>
#include <map>
#include <utility>
#include <vector>

namespace tugboat {
namespace engine {

template <typename Key, typename Value>
class OrderedMap {
 public:
  using Entry = std::pair<Key, Value>;

  OrderedMap() = default;
  // The index holds iterators into `entries_`, so copies rebuild it.
  OrderedMap(const OrderedMap& other) : entries_(other.entries_) { reindex(); }
  OrderedMap& operator=(const OrderedMap& other) {
    if (this != &other) {
      entries_ = other.entries_;
      reindex();
    }
    return *this;
  }
  OrderedMap(OrderedMap&&) noexcept = default;
  OrderedMap& operator=(OrderedMap&&) noexcept = default;

  bool empty() const { return entries_.empty(); }
  size_t size() const { return entries_.size(); }
  bool contains(const Key& key) const { return index_.count(key) != 0; }

  Value* find(const Key& key) {
    const auto it = index_.find(key);
    return it == index_.end() ? nullptr : &it->second->second;
  }
  const Value* find(const Key& key) const {
    const auto it = index_.find(key);
    return it == index_.end() ? nullptr : &it->second->second;
  }

  // Dart `map[key] = value`: replaces in place, else appends.
  void put(const Key& key, Value value) {
    if (Value* existing = find(key)) {
      *existing = std::move(value);
      return;
    }
    entries_.emplace_back(key, std::move(value));
    index_.emplace(key, std::prev(entries_.end()));
  }

  // Dart `map.remove(key)`: true when the key was present.
  bool erase(const Key& key) {
    const auto it = index_.find(key);
    if (it == index_.end()) return false;
    entries_.erase(it->second);
    index_.erase(it);
    return true;
  }

  void clear() {
    entries_.clear();
    index_.clear();
  }

  // Entries in insertion order. Values may be changed through it; keys and
  // membership only through `put` and `erase`.
  const std::list<Entry>& entries() const { return entries_; }
  std::list<Entry>& entries() { return entries_; }

  std::vector<Key> keys() const {
    std::vector<Key> out;
    for (const Entry& entry : entries_) out.push_back(entry.first);
    return out;
  }

 private:
  void reindex() {
    index_.clear();
    for (auto it = entries_.begin(); it != entries_.end(); ++it) {
      index_.emplace(it->first, it);
    }
  }

  std::list<Entry> entries_;
  std::map<Key, typename std::list<Entry>::iterator> index_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_ORDERED_MAP_H
