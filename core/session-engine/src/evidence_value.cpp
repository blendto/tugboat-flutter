#include "evidence_value.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace tugboat {
namespace engine {

namespace {

const Value* member(const Value& object, const char* key) {
  return object.find(key);
}

double double_tag(const Value& v) {
  if (v.is_number()) {
    return v.to_double();
  }
  const std::string& s = v.as_string();
  if (s == "NaN") {
    return std::numeric_limits<double>::quiet_NaN();
  }
  if (s == "Infinity") {
    return std::numeric_limits<double>::infinity();
  }
  if (s == "-Infinity") {
    return -std::numeric_limits<double>::infinity();
  }
  return -0.0;  // "-0.0"
}

bool is_count(const Value* v) { return v != nullptr && v->is_int() && v->as_int() >= 1; }

std::string at_index(const std::string& path, size_t i) {
  return path + "[" + std::to_string(i) + "]";
}

bool validate_items(const Value& items, int64_t depth,
                    const std::string& path, Error* error) {
  if (!items.is_array()) {
    return invalid(error, path, "expected an array");
  }
  for (size_t i = 0; i < items.items().size(); ++i) {
    if (!validate_value(items.items()[i], depth, false, at_index(path, i),
                        error)) {
      return false;
    }
  }
  return true;
}

// `{tag: ..., "omitted"?: n}`.
bool validate_collection_keys(const Value& v, const std::string& path,
                              Error* error) {
  const Value* omitted = member(v, "omitted");
  if (v.members().size() != (omitted != nullptr ? 2u : 1u)) {
    return invalid(error, path, "unexpected key beside the collection tag");
  }
  if (omitted != nullptr && !is_count(omitted)) {
    return invalid(error, path + ".omitted", "expected an integer >= 1");
  }
  return true;
}

bool validate_double(const Value& v, const std::string& path, Error* error) {
  if (v.is_number()) {
    return true;
  }
  if (v.is_string()) {
    const std::string& s = v.as_string();
    if (s == "NaN" || s == "Infinity" || s == "-Infinity" || s == "-0.0") {
      return true;
    }
  }
  return invalid(error, path,
                 "expected a number, NaN, Infinity, -Infinity, or -0.0");
}

bool validate_flag(const Value& v, const std::string& path, Error* error) {
  if (!v.is_bool() || !v.as_bool()) {
    return invalid(error, path, "expected true");
  }
  return true;
}

bool validate_tag(const Value& v, int64_t depth, bool allow_drop,
                  const std::string& path, Error* error) {
  const size_t size = v.members().size();
  if (const Value* list = member(v, "list")) {
    return validate_collection_keys(v, path, error) &&
           validate_items(*list, depth + 1, path + ".list", error);
  }
  if (const Value* iterable = member(v, "iterable")) {
    return validate_collection_keys(v, path, error) &&
           validate_items(*iterable, depth + 1, path + ".iterable", error);
  }
  if (member(v, "map") != nullptr) {
    return validate_collection_keys(v, path, error) &&
           validate_map(v, depth + 1, false, path, error);
  }
  if (size != 1) {
    return invalid(error, path, "expected exactly one value tag");
  }
  const Member& tag = v.members()[0];
  const std::string child = path + "." + tag.key;
  if (tag.key == "double") {
    return validate_double(tag.value, child, error);
  }
  if (tag.key == "unsupported") {
    return validate_flag(tag.value, child, error);
  }
  if (tag.key == "drop") {
    if (!allow_drop) {
      return invalid(error, child,
                     "drop is only a top-level parameter value under "
                     "transform");
    }
    return validate_flag(tag.value, child, error);
  }
  if (tag.key == "ref") {
    if (!is_count(&tag.value) || tag.value.as_int() > depth) {
      return invalid(error, child,
                     "expected an enclosing collection count (1 to " +
                         std::to_string(depth) + ")");
    }
    return true;
  }
  return invalid(error, path, "unknown value tag " + tag.key);
}

bool validate_entry(const Value& entry, int64_t depth, bool allow_drop,
                    const std::string& path, Error* error) {
  if (entry.is_object()) {
    const Value* run = member(entry, "nonStringKeys");
    if (entry.members().size() != 1 || !is_count(run)) {
      return invalid(error, path, "expected {\"nonStringKeys\": n >= 1}");
    }
    return true;
  }
  if (!entry.is_array() || entry.items().size() != 2 ||
      !entry.items()[0].is_string()) {
    return invalid(error, path, "expected [key, value] with a string key");
  }
  return validate_value(entry.items()[1], depth, allow_drop, path + "[1]",
                        error);
}

bool has_duplicate_keys(const std::vector<Value>& entries) {
  std::vector<const std::string*> keys;
  for (const Value& entry : entries) {
    if (entry.is_array()) {
      keys.push_back(&entry.items()[0].as_string());
    }
  }
  std::sort(keys.begin(), keys.end(),
            [](const std::string* a, const std::string* b) { return *a < *b; });
  return std::adjacent_find(keys.begin(), keys.end(),
                            [](const std::string* a, const std::string* b) {
                              return *a == *b;
                            }) != keys.end();
}

}  // namespace

int64_t add_count(int64_t a, int64_t b) {
  constexpr int64_t kMax = std::numeric_limits<int64_t>::max();
  return a > kMax - b ? kMax : a + b;
}

bool validate_map(const Value& tag, int64_t depth, bool allow_drop,
                  const std::string& path, Error* error) {
  const Value* entries = member(tag, "map");
  const std::string child = path + ".map";
  if (entries == nullptr || !entries->is_array()) {
    return invalid(error, child, "expected an array of entries");
  }
  for (size_t i = 0; i < entries->items().size(); ++i) {
    if (!validate_entry(entries->items()[i], depth, allow_drop,
                        at_index(child, i), error)) {
      return false;
    }
  }
  if (has_duplicate_keys(entries->items())) {
    return invalid(error, child, "duplicate map key");
  }
  return true;
}

bool validate_value(const Value& value, int64_t depth, bool allow_drop,
                    const std::string& path, Error* error) {
  switch (value.kind()) {
    case Value::Kind::kNull:
    case Value::Kind::kBool:
    case Value::Kind::kInt:
    case Value::Kind::kString:
      return true;
    case Value::Kind::kDouble:
      return invalid(error, path,
                     "a bare number must be an integer; write doubles as "
                     "{\"double\": x}");
    case Value::Kind::kArray:
      return validate_items(value, depth + 1, path, error);
    case Value::Kind::kObject:
      return validate_tag(value, depth, allow_drop, path, error);
  }
  return false;
}

Node::Node(const Value& value, bool plain) : value_(&value), plain_(plain) {
  switch (value.kind()) {
    case Value::Kind::kNull:
      kind_ = NodeKind::kNull;
      return;
    case Value::Kind::kBool:
      kind_ = NodeKind::kBool;
      return;
    case Value::Kind::kInt:
      kind_ = NodeKind::kInt;
      return;
    case Value::Kind::kDouble:
      kind_ = NodeKind::kDouble;
      number_ = value.as_double();
      return;
    case Value::Kind::kString:
      kind_ = NodeKind::kString;
      return;
    case Value::Kind::kArray:
      kind_ = NodeKind::kList;
      items_ = &value.items();
      return;
    case Value::Kind::kObject:
      break;
  }
  if (plain) {
    kind_ = NodeKind::kMap;
    members_ = &value.members();
    return;
  }
  if (const Value* omitted = value.find("omitted")) {
    omitted_ = omitted->as_int();
  }
  if (const Value* list = value.find("list")) {
    kind_ = NodeKind::kList;
    items_ = &list->items();
  } else if (const Value* iterable = value.find("iterable")) {
    kind_ = NodeKind::kIterable;
    items_ = &iterable->items();
  } else if (const Value* map = value.find("map")) {
    kind_ = NodeKind::kMap;
    items_ = &map->items();
  } else if (const Value* number = value.find("double")) {
    kind_ = NodeKind::kDouble;
    number_ = double_tag(*number);
  } else if (const Value* ref = value.find("ref")) {
    kind_ = NodeKind::kRef;
    ref_ = ref->as_int();
  } else if (value.find("drop") != nullptr) {
    kind_ = NodeKind::kDrop;
  } else {
    kind_ = NodeKind::kUnsupported;
  }
}

size_t Node::size() const {
  if (members_ != nullptr) {
    return members_->size();
  }
  return items_ == nullptr ? 0 : items_->size();
}

Node Node::item(size_t i) const { return Node((*items_)[i], plain_); }

Entry Node::entry(size_t i) const {
  Entry out;
  if (members_ != nullptr) {
    out.key = &(*members_)[i].key;
    out.value = &(*members_)[i].value;
    return out;
  }
  const Value& raw = (*items_)[i];
  if (raw.is_object()) {
    out.run = raw.members()[0].value.as_int();
    return out;
  }
  out.key = &raw.items()[0].as_string();
  out.value = &raw.items()[1];
  return out;
}

int64_t entry_count(const Node& map) {
  int64_t count = 0;
  for (size_t i = 0; i < map.size(); ++i) {
    const Entry entry = map.entry(i);
    count = add_count(count, entry.key != nullptr ? 1 : entry.run);
  }
  return count;
}

}  // namespace engine
}  // namespace tugboat
