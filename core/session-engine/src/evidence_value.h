// The typed value encoding of the evidence messages (docs/
// evidence-messages.md section 2), decoded once into `EvidenceValue`: the
// host-typed values Dart's rules run on. `jsonText` bodies convert into the
// same tree. Not part of the C ABI.
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

enum class EvidenceKind {
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

struct EvidenceEntry;

struct EvidenceValue {
  EvidenceKind kind = EvidenceKind::kNull;
  bool boolean = false;
  int64_t integer = 0;  // kInt; kRef: how many collections up
  double number = 0;
  std::string string;
  std::vector<EvidenceValue> items;    // kList, kIterable
  std::vector<EvidenceEntry> entries;  // kMap, in host order
  int64_t omitted = 0;  // kList, kIterable, kMap: items the host left out

  bool is_collection() const {
    return kind == EvidenceKind::kList || kind == EvidenceKind::kIterable ||
           kind == EvidenceKind::kMap;
  }
};

// A map entry: a string key and its value, or (`non_string_keys` > 0) a run
// of that many entries whose keys are not strings.
struct EvidenceEntry {
  std::string key;
  EvidenceValue value;
  int64_t non_string_keys = 0;
};

// What a value is decoded for: parameter maps reject a repeated key; body
// maps keep it, because a host's cut can make two long keys equal.
enum class EvidenceContext { kParameters, kErrorBody };

// Decodes one encoded value (an error body's `value`). Fails with the JSON
// path, rooted at `path`, on an invalid encoding.
bool decode_evidence_value(const Value& json, EvidenceContext context,
                           const std::string& path, EvidenceValue* out,
                           Error* error);

// Decodes the parameters `map` value: its entry values are roots (the map
// is not a collection of any value), `drop` is allowed as an entry value
// when `transform`, and `omitted` needs 64 sent entries.
bool decode_parameters_map(const Value& json, bool transform,
                           const std::string& path, EvidenceValue* out,
                           Error* error);

// Decoded JSON (a `jsonText` body) as a value: objects are maps.
EvidenceValue evidence_from_json(const Value& decoded);

// Saturating addition of non-negative counts.
int64_t add_count(int64_t a, int64_t b);

// A map's entries, counting each run by its length (saturating).
int64_t entry_count(const EvidenceValue& map);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_EVIDENCE_VALUE_H
