// Dart `snapshotExternalParameters` and `recordExternalEvent`'s data
// (docs/evidence-messages.md section 3.1).
#include <algorithm>
#include <cmath>
#include <utility>

#include "evidence.h"
#include "evidence_value.h"
#include "name_table.h"
#include "text.h"

namespace tugboat {
namespace engine {

namespace {

using Limits = ParameterLimits;

constexpr NamedValue<ParameterMode> kModes[] = {
    {"names_only", ParameterMode::kNamesOnly},
    {"allow_list", ParameterMode::kAllowList},
    {"transform", ParameterMode::kTransform},
    {"allow_all", ParameterMode::kAllowAll},
};

bool is_valid_key(const std::string& key) {
  return !key.empty() && !utf16_longer_than(key, Limits::kMaxKeyLength);
}

// Dart `_ParameterSnapshotState`.
struct SnapshotState {
  Value keys = Value::array();
  Value retained = Value::object();
  int64_t dropped = 0;
  bool truncated = false;
  size_t collection_items = 0;

  void add_dropped(int64_t count) {
    dropped = add_count(dropped, count);
    truncated = true;
  }
  void increment_dropped(int64_t count) { dropped = add_count(dropped, count); }
  bool accept_collection_item() {
    collection_items += 1;
    if (collection_items > Limits::kMaxCollectionItems) {
      truncated = true;
      return false;
    }
    return true;
  }
};

class Copier {
 public:
  explicit Copier(SnapshotState* state) : state_(*state) {}

  // Dart `_copyJsonSafe`: false when the value is left out.
  bool copy(const EvidenceValue& value, size_t depth, Value* out) {
    if (depth > Limits::kMaxDepth) {
      return drop();
    }
    switch (value.kind) {
      case EvidenceKind::kNull:
        *out = Value::null();
        return true;
      case EvidenceKind::kBool:
        *out = Value::boolean(value.boolean);
        return true;
      case EvidenceKind::kInt:
        *out = Value::integer(value.integer);
        return true;
      case EvidenceKind::kDouble:
        if (!std::isfinite(value.number)) {
          return drop();
        }
        *out = Value::number(value.number);
        return true;
      case EvidenceKind::kString:
        if (utf16_longer_than(value.string, Limits::kMaxStringLength)) {
          return drop();
        }
        *out = Value::string(value.string);
        return true;
      case EvidenceKind::kMap:
        *out = copy_map(value, depth);
        return true;
      case EvidenceKind::kList:
      case EvidenceKind::kIterable:
        *out = copy_items(value, depth);
        return true;
      case EvidenceKind::kRef:  // a cycle: Dart's `seen` check
      case EvidenceKind::kUnsupported:
      case EvidenceKind::kDrop:
        return drop();
    }
    return drop();
  }

 private:
  bool drop() {
    state_.add_dropped(1);
    return false;
  }

  // Items the host omitted stand in as unsupported values, each counted.
  void omitted_items(const EvidenceValue& value) {
    for (int64_t i = 0; i < value.omitted; ++i) {
      const bool accepted = state_.accept_collection_item();
      drop();
      if (!accepted) {
        return;
      }
    }
  }

  Value copy_map(const EvidenceValue& map, size_t depth) {
    Value out = Value::object();
    for (const EvidenceEntry& entry : map.entries) {
      if (entry.non_string_keys > 0) {
        state_.add_dropped(entry.non_string_keys);
        continue;
      }
      if (!is_valid_key(entry.key)) {
        drop();
        continue;
      }
      if (!state_.accept_collection_item()) {
        drop();
        return out;
      }
      Value copied;
      if (copy(entry.value, depth + 1, &copied)) {
        out.set(entry.key, std::move(copied));
      }
    }
    omitted_items(map);
    return out;
  }

  Value copy_items(const EvidenceValue& list, size_t depth) {
    Value out = Value::array();
    for (const EvidenceValue& item : list.items) {
      if (!state_.accept_collection_item()) {
        drop();
        return out;
      }
      Value copied;
      if (copy(item, depth + 1, &copied)) {
        out.push(std::move(copied));
      }
    }
    omitted_items(list);
    return out;
  }

  SnapshotState& state_;
};

bool allowed(const ParameterPolicy& policy, const std::string& key) {
  return std::binary_search(policy.allowed_keys.begin(),
                            policy.allowed_keys.end(), key);
}

// Dart `_retainSnapshotValue` with `_decideTopLevelValue`.
void retain(const ParameterPolicy& policy, const EvidenceEntry& entry,
            SnapshotState* state) {
  switch (policy.mode) {
    case ParameterMode::kNamesOnly:
      return;
    case ParameterMode::kAllowList:
      if (!allowed(policy, entry.key)) {
        state->increment_dropped(1);
        return;
      }
      break;
    case ParameterMode::kTransform:
      if (entry.value.kind == EvidenceKind::kDrop) {
        state->increment_dropped(1);
        return;
      }
      break;
    case ParameterMode::kAllowAll:
      break;
  }
  Value copied;
  if (Copier(state).copy(entry.value, 1, &copied)) {
    state->retained.set(entry.key, std::move(copied));
  }
}

// The first 64 entries (Dart `raw.entries.take(64)`).
void snapshot_entries(const ParameterPolicy& policy, const EvidenceValue& map,
                      SnapshotState* state) {
  int64_t taken = 0;
  constexpr auto kMaxKeys = static_cast<int64_t>(Limits::kMaxTopLevelKeys);
  for (const EvidenceEntry& entry : map.entries) {
    if (taken >= kMaxKeys) {
      return;
    }
    if (entry.non_string_keys > 0) {
      const int64_t run = std::min(entry.non_string_keys, kMaxKeys - taken);
      taken += run;
      state->add_dropped(run);
      continue;
    }
    taken += 1;
    if (!is_valid_key(entry.key)) {
      state->add_dropped(1);
      continue;
    }
    state->keys.push(Value::string(entry.key));
    retain(policy, entry, state);
  }
}

// Dart `_boundedParametersOut`.
std::optional<Value> bounded_parameters(const ParameterPolicy& policy,
                                        SnapshotState* state) {
  if (policy.mode == ParameterMode::kNamesOnly ||
      state->retained.members().empty()) {
    return std::nullopt;
  }
  if (encode_json(state->retained).size() <= Limits::kMaxEncodedBytes) {
    return std::move(state->retained);
  }
  state->add_dropped(static_cast<int64_t>(state->retained.members().size()));
  return std::nullopt;
}

}  // namespace

std::optional<ParameterMode> parse_parameter_mode(const std::string& name) {
  return parse_name(kModes, name);
}

const char* parameter_mode_name(ParameterMode mode) {
  return name_of(kModes, mode);
}

std::optional<std::string> bound_external_label(std::string_view value,
                                                size_t max_units) {
  const std::string_view trimmed = dart_trim(value);
  if (trimmed.empty()) {
    return std::nullopt;
  }
  return utf16_prefix(trimmed, max_units);
}

std::optional<Value> external_event_data(
    std::string_view name, const std::optional<std::string>& source,
    const ParameterPolicy& policy, const EvidenceValue* parameters) {
  const std::optional<std::string> bounded_name =
      bound_external_label(name, Limits::kMaxNameLength);
  if (!bounded_name) {
    return std::nullopt;
  }
  std::optional<std::string> bounded_source;
  if (source) {
    bounded_source = bound_external_label(*source, Limits::kMaxSourceLength);
  }
  SnapshotState state;
  std::optional<Value> retained;
  if (parameters != nullptr) {
    const int64_t total =
        add_count(entry_count(*parameters), parameters->omitted);
    constexpr auto kMaxKeys = static_cast<int64_t>(Limits::kMaxTopLevelKeys);
    if (total > kMaxKeys) {
      state.add_dropped(total - kMaxKeys);
    }
    snapshot_entries(policy, *parameters, &state);
    retained = bounded_parameters(policy, &state);
  }
  Value data = Value::object();
  if (bounded_source) {
    data.set("source", Value::string(*bounded_source));
  }
  data.set("name", Value::string(*bounded_name));
  data.set("parameterKeys", std::move(state.keys));
  if (retained) {
    data.set("parameters", std::move(*retained));
  }
  Value capture = Value::object();
  capture.set("values", Value::string(parameter_mode_name(policy.mode)));
  capture.set("truncated", Value::boolean(state.truncated));
  capture.set("droppedCount", Value::integer(state.dropped));
  data.set("capture", std::move(capture));
  return data;
}

}  // namespace engine
}  // namespace tugboat
