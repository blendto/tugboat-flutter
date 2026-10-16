// Dart `snapshotExternalParameters` and `recordExternalEvent`'s data
// (docs/evidence-messages.md section 3.1).
#include <algorithm>
#include <cmath>

#include "dart_string.h"
#include "evidence.h"
#include "evidence_value.h"

namespace tugboat {
namespace engine {

namespace {

using Limits = ParameterLimits;

bool is_valid_key(const std::string* key) {
  return key != nullptr && !key->empty() &&
         !utf16_longer_than(*key, Limits::kMaxKeyLength);
}

// Dart `_ParameterSnapshotState`.
struct SnapshotState {
  Value keys = Value::array();
  Value retained = Value::object();
  int64_t dropped = 0;
  bool truncated = false;
  int64_t collection_items = 0;

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
  bool copy(const Node& node, int64_t depth, Value* out) {
    if (depth > Limits::kMaxDepth) {
      return drop();
    }
    switch (node.kind()) {
      case NodeKind::kNull:
      case NodeKind::kBool:
      case NodeKind::kInt:
        *out = node.value();
        return true;
      case NodeKind::kDouble:
        if (!std::isfinite(node.number())) {
          return drop();
        }
        *out = Value::number(node.number());
        return true;
      case NodeKind::kString:
        if (utf16_longer_than(node.value().as_string(),
                              Limits::kMaxStringLength)) {
          return drop();
        }
        *out = node.value();
        return true;
      case NodeKind::kMap:
        *out = copy_map(node, depth);
        return true;
      case NodeKind::kList:
      case NodeKind::kIterable:
        *out = copy_items(node, depth);
        return true;
      case NodeKind::kRef:  // a cycle: Dart's `seen` check
      case NodeKind::kUnsupported:
      case NodeKind::kDrop:
        return drop();
    }
    return drop();
  }

 private:
  bool drop() {
    state_.add_dropped(1);
    return false;
  }

  // An item the host omitted: an unsupported value. False ends the
  // collection.
  bool omitted_item() {
    if (!state_.accept_collection_item()) {
      drop();
      return false;
    }
    drop();
    return true;
  }

  void omitted_items(const Node& node) {
    for (int64_t i = 0; i < node.omitted(); ++i) {
      if (!omitted_item()) {
        return;
      }
    }
  }

  Value copy_map(const Node& node, int64_t depth) {
    Value out = Value::object();
    for (size_t i = 0; i < node.size(); ++i) {
      const Entry entry = node.entry(i);
      if (entry.key == nullptr) {
        state_.add_dropped(entry.run);
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
      if (copy(node.child(*entry.value), depth + 1, &copied)) {
        out.set(*entry.key, std::move(copied));
      }
    }
    omitted_items(node);
    return out;
  }

  Value copy_items(const Node& node, int64_t depth) {
    Value out = Value::array();
    for (size_t i = 0; i < node.size(); ++i) {
      if (!state_.accept_collection_item()) {
        drop();
        return out;
      }
      Value copied;
      if (copy(node.item(i), depth + 1, &copied)) {
        out.push(std::move(copied));
      }
    }
    omitted_items(node);
    return out;
  }

  SnapshotState& state_;
};

bool allowed(const ParameterPolicy& policy, const std::string& key) {
  return std::binary_search(policy.allowed_keys.begin(),
                            policy.allowed_keys.end(), key);
}

// Dart `_retainSnapshotValue` with `_decideTopLevelValue`.
void retain(const ParameterPolicy& policy, const std::string& key,
            const Node& value, SnapshotState* state) {
  switch (policy.mode) {
    case ParameterMode::kNamesOnly:
      return;
    case ParameterMode::kAllowList:
      if (!allowed(policy, key)) {
        state->increment_dropped(1);
        return;
      }
      break;
    case ParameterMode::kTransform:
      if (value.kind() == NodeKind::kDrop) {
        state->increment_dropped(1);
        return;
      }
      break;
    case ParameterMode::kAllowAll:
      break;
  }
  Value copied;
  if (Copier(state).copy(value, 1, &copied)) {
    state->retained.set(key, std::move(copied));
  }
}

void snapshot_entries(const ParameterPolicy& policy, const Node& map,
                      SnapshotState* state) {
  int64_t taken = 0;
  for (size_t i = 0; i < map.size() && taken < Limits::kMaxTopLevelKeys;
       ++i) {
    const Entry entry = map.entry(i);
    if (entry.key == nullptr) {
      const int64_t run =
          std::min(entry.run, Limits::kMaxTopLevelKeys - taken);
      taken += run;
      state->add_dropped(run);
      continue;
    }
    taken += 1;
    if (!is_valid_key(entry.key)) {
      state->add_dropped(1);
      continue;
    }
    state->keys.push(Value::string(*entry.key));
    retain(policy, *entry.key, map.child(*entry.value), state);
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
  if (name == "names_only") {
    return ParameterMode::kNamesOnly;
  }
  if (name == "allow_list") {
    return ParameterMode::kAllowList;
  }
  if (name == "transform") {
    return ParameterMode::kTransform;
  }
  if (name == "allow_all") {
    return ParameterMode::kAllowAll;
  }
  return std::nullopt;
}

const char* parameter_mode_name(ParameterMode mode) {
  switch (mode) {
    case ParameterMode::kNamesOnly:
      return "names_only";
    case ParameterMode::kAllowList:
      return "allow_list";
    case ParameterMode::kTransform:
      return "transform";
    case ParameterMode::kAllowAll:
      return "allow_all";
  }
  return "allow_all";
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
    const ParameterPolicy& policy, const Value* parameters) {
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
    const Node map = Node::encoded(*parameters);
    const int64_t total = add_count(entry_count(map), map.omitted());
    if (total > Limits::kMaxTopLevelKeys) {
      state.add_dropped(total - Limits::kMaxTopLevelKeys);
    }
    snapshot_entries(policy, map, &state);
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
