// The typed value encoding of the evidence messages (docs/
// evidence-messages.md section 2): how a host writes parameter values and
// error bodies so the engine can apply Dart's rules to them. Not part of
// the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_EVIDENCE_VALUE_H
#define TUGBOAT_SESSION_ENGINE_EVIDENCE_VALUE_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "json.h"
#include "reader.h"

namespace tugboat {
namespace engine {

enum class NodeKind {
  kNull,
  kBool,
  kInt,
  kDouble,
  kString,
  kList,      // Dart `List`
  kIterable,  // any other Dart `Iterable`
  kMap,
  kRef,  // an ancestor collection (a cycle)
  kUnsupported,
  kDrop,  // the transform drop sentinel
};

// One map entry: a string key and its value, or a run of `run` entries whose
// keys are not strings (their values are never read).
struct Entry {
  const std::string* key = nullptr;
  const Value* value = nullptr;
  int64_t run = 0;
};

// A read-only view of one value, over a validated encoded value or over
// plain decoded JSON (a `jsonText` body, where objects are maps).
class Node {
 public:
  static Node encoded(const Value& value) { return Node(value, false); }
  static Node plain(const Value& value) { return Node(value, true); }

  NodeKind kind() const { return kind_; }
  const Value& value() const { return *value_; }
  bool is_plain() const { return plain_; }
  // kDouble.
  double number() const { return number_; }
  // kRef: how many collections up.
  int64_t ref() const { return ref_; }

  // kList, kIterable, kMap: the sent items, and how many more the host
  // omitted.
  size_t size() const;
  int64_t omitted() const { return omitted_; }
  // kList, kIterable.
  Node item(size_t i) const;
  // kMap.
  Entry entry(size_t i) const;
  Node child(const Value& value) const { return Node(value, plain_); }

 private:
  Node(const Value& value, bool plain);

  const Value* value_;
  bool plain_;
  NodeKind kind_ = NodeKind::kUnsupported;
  double number_ = 0;
  int64_t ref_ = 0;
  int64_t omitted_ = 0;
  const std::vector<Value>* items_ = nullptr;     // list, iterable, map
  const std::vector<Member>* members_ = nullptr;  // plain map
};

// Entries of a map, counting each `nonStringKeys` run by its length
// (saturating).
int64_t entry_count(const Node& map);

// Saturating addition of non-negative counts.
int64_t add_count(int64_t a, int64_t b);

// Validates an encoded value. `depth` is the number of enclosing collections
// within the value (bounds `ref`); `allow_drop` admits `{"drop": true}`.
bool validate_value(const Value& value, int64_t depth, bool allow_drop,
                    const std::string& path, Error* error);

// Validates a map's entries (duplicate keys are invalid); `allow_drop`
// applies to the entry values.
bool validate_map(const Value& tag, int64_t depth, bool allow_drop,
                  const std::string& path, Error* error);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_EVIDENCE_VALUE_H
