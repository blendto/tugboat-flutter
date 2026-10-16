#include "evidence_value.h"

#include <algorithm>
#include <limits>
#include <optional>
#include <utility>

#include "name_table.h"

namespace tugboat {
namespace engine {

namespace {

// A JSON path built only when an error needs it: the success path never
// allocates one per item.
class Path {
 public:
  explicit Path(const std::string& root) : root_(&root) {}
  Path(const Path& parent, const char* key) : parent_(&parent), key_(key) {}
  Path(const Path& parent, size_t index)
      : parent_(&parent), index_(index), is_index_(true) {}

  std::string str() const {
    if (parent_ == nullptr) {
      return *root_;
    }
    return parent_->str() +
           (is_index_ ? "[" + std::to_string(index_) + "]"
                      : std::string(".") + key_);
  }

 private:
  const std::string* root_ = nullptr;
  const Path* parent_ = nullptr;
  const char* key_ = "";
  size_t index_ = 0;
  bool is_index_ = false;
};

constexpr NamedValue<EvidenceKind> kTags[] = {
    {"list", EvidenceKind::kList},
    {"iterable", EvidenceKind::kIterable},
    {"map", EvidenceKind::kMap},
    {"double", EvidenceKind::kDouble},
    {"ref", EvidenceKind::kRef},
    {"unsupported", EvidenceKind::kUnsupported},
    {"drop", EvidenceKind::kDrop},
};

bool is_count(const Value& v) { return v.is_int() && v.as_int() >= 1; }

class Decoder {
 public:
  Decoder(EvidenceContext context, Error* error)
      : context_(context), error_(error) {}

  // `depth`: enclosing collections within the value. `allow_drop`: this
  // value may be `{"drop": true}`.
  bool value(const Value& json, int64_t depth, bool allow_drop,
             const Path& path, EvidenceValue* out) {
    switch (json.kind()) {
      case Value::Kind::kNull:
        out->kind = EvidenceKind::kNull;
        return true;
      case Value::Kind::kBool:
        out->kind = EvidenceKind::kBool;
        out->boolean = json.as_bool();
        return true;
      case Value::Kind::kInt:
        out->kind = EvidenceKind::kInt;
        out->integer = json.as_int();
        return true;
      case Value::Kind::kString:
        out->kind = EvidenceKind::kString;
        out->string = json.as_string();
        return true;
      case Value::Kind::kDouble:
        return fail(path,
                    "a bare number must be an integer; write doubles as "
                    "{\"double\": x}");
      case Value::Kind::kArray:
        out->kind = EvidenceKind::kList;
        return items(json, depth + 1, path, out);
      case Value::Kind::kObject:
        return tag(json, depth, allow_drop, path, out);
    }
    return false;
  }

  // A map's entries (`entries` is the tag's array); entry values are at
  // `depth`.
  bool map(const Value& entries, int64_t depth, bool allow_drop,
           const Path& path, EvidenceValue* out) {
    if (!entries.is_array()) {
      return fail(path, "expected an array of entries");
    }
    out->kind = EvidenceKind::kMap;
    out->entries.resize(entries.items().size());
    for (size_t i = 0; i < entries.items().size(); ++i) {
      if (!entry(entries.items()[i], depth, allow_drop, Path(path, i),
                 &out->entries[i])) {
        return false;
      }
    }
    if (context_ == EvidenceContext::kParameters && has_repeated_key(*out)) {
      return fail(path, "duplicate map key");
    }
    return true;
  }

  bool fail(const Path& path, std::string message) {
    return invalid(error_, path.str(), std::move(message));
  }

 private:
  bool tag(const Value& json, int64_t depth, bool allow_drop,
           const Path& path, EvidenceValue* out) {
    const Member* tag = nullptr;
    const Value* omitted = nullptr;
    for (const Member& member : json.members()) {
      if (member.key == "omitted" && omitted == nullptr) {
        omitted = &member.value;
      } else if (tag == nullptr) {
        tag = &member;
      } else {
        return fail(path, "expected exactly one value tag");
      }
    }
    if (tag == nullptr) {
      return fail(path, "expected a value tag");
    }
    const std::optional<EvidenceKind> kind = parse_name(kTags, tag->key);
    if (!kind) {
      return fail(path, "unknown value tag " + tag->key);
    }
    out->kind = *kind;
    if (omitted != nullptr) {
      if (!out->is_collection()) {
        return fail(path, "unexpected key beside the value tag");
      }
      if (!is_count(*omitted)) {
        return fail(Path(path, "omitted"), "expected an integer >= 1");
      }
      out->omitted = omitted->as_int();
    }
    return tag_value(*kind, tag->value, depth, allow_drop,
                     Path(path, tag->key.c_str()), out);
  }

  bool tag_value(EvidenceKind kind, const Value& json, int64_t depth,
                 bool allow_drop, const Path& path, EvidenceValue* out) {
    switch (kind) {
      case EvidenceKind::kList:
      case EvidenceKind::kIterable:
        return items(json, depth + 1, path, out);
      case EvidenceKind::kMap:
        return map(json, depth + 1, false, path, out);
      case EvidenceKind::kDouble:
        return number(json, path, out);
      case EvidenceKind::kRef:
        if (!is_count(json) || json.as_int() > depth) {
          return fail(path, "expected an enclosing collection count (1 to " +
                                std::to_string(depth) + ")");
        }
        out->integer = json.as_int();
        return true;
      case EvidenceKind::kDrop:
        if (!allow_drop) {
          return fail(path,
                      "drop is only a top-level parameter value under "
                      "transform");
        }
        return flag(json, path);
      default:  // kUnsupported
        return flag(json, path);
    }
  }

  bool items(const Value& json, int64_t depth, const Path& path,
             EvidenceValue* out) {
    if (!json.is_array()) {
      return fail(path, "expected an array");
    }
    out->items.resize(json.items().size());
    for (size_t i = 0; i < json.items().size(); ++i) {
      if (!value(json.items()[i], depth, false, Path(path, i),
                 &out->items[i])) {
        return false;
      }
    }
    return true;
  }

  bool entry(const Value& json, int64_t depth, bool allow_drop,
             const Path& path, EvidenceEntry* out) {
    if (json.is_object()) {
      const Value* run = json.find("nonStringKeys");
      if (json.members().size() != 1 || run == nullptr || !is_count(*run)) {
        return fail(path, "expected {\"nonStringKeys\": n >= 1}");
      }
      out->non_string_keys = run->as_int();
      return true;
    }
    if (!json.is_array() || json.items().size() != 2 ||
        !json.items()[0].is_string()) {
      return fail(path, "expected [key, value] with a string key");
    }
    out->key = json.items()[0].as_string();
    return value(json.items()[1], depth, allow_drop, Path(path, 1),
                 &out->value);
  }

  bool number(const Value& json, const Path& path, EvidenceValue* out) {
    out->kind = EvidenceKind::kDouble;
    if (json.is_number()) {
      out->number = json.to_double();
      return true;
    }
    const std::string* name = json.is_string() ? &json.as_string() : nullptr;
    if (name != nullptr && *name == "NaN") {
      out->number = std::numeric_limits<double>::quiet_NaN();
    } else if (name != nullptr && *name == "Infinity") {
      out->number = std::numeric_limits<double>::infinity();
    } else if (name != nullptr && *name == "-Infinity") {
      out->number = -std::numeric_limits<double>::infinity();
    } else if (name != nullptr && *name == "-0.0") {
      out->number = -0.0;
    } else {
      return fail(path,
                  "expected a number, NaN, Infinity, -Infinity, or -0.0");
    }
    return true;
  }

  bool flag(const Value& json, const Path& path) {
    if (!json.is_bool() || !json.as_bool()) {
      return fail(path, "expected true");
    }
    return true;
  }

  static bool has_repeated_key(const EvidenceValue& map) {
    std::vector<const std::string*> keys;
    for (const EvidenceEntry& entry : map.entries) {
      if (entry.non_string_keys == 0) {
        keys.push_back(&entry.key);
      }
    }
    std::sort(keys.begin(), keys.end(),
              [](const std::string* a, const std::string* b) {
                return *a < *b;
              });
    return std::adjacent_find(keys.begin(), keys.end(),
                              [](const std::string* a, const std::string* b) {
                                return *a == *b;
                              }) != keys.end();
  }

  EvidenceContext context_;
  Error* error_;
};

}  // namespace

int64_t add_count(int64_t a, int64_t b) {
  constexpr int64_t kMax = std::numeric_limits<int64_t>::max();
  return a > kMax - b ? kMax : a + b;
}

int64_t entry_count(const EvidenceValue& map) {
  int64_t count = 0;
  for (const EvidenceEntry& entry : map.entries) {
    count = add_count(count, entry.non_string_keys > 0 ? entry.non_string_keys
                                                       : 1);
  }
  return count;
}

bool decode_evidence_value(const Value& json, EvidenceContext context,
                           const std::string& path, EvidenceValue* out,
                           Error* error) {
  return Decoder(context, error).value(json, 0, false, Path(path), out);
}

bool decode_parameters_map(const Value& json, bool transform,
                           const std::string& path, EvidenceValue* out,
                           Error* error) {
  Decoder decoder(EvidenceContext::kParameters, error);
  const Path root(path);
  const Value* entries = json.is_object() ? json.find("map") : nullptr;
  const Value* omitted = json.is_object() ? json.find("omitted") : nullptr;
  if (entries == nullptr ||
      json.members().size() != (omitted != nullptr ? 2u : 1u)) {
    return decoder.fail(root, "expected a map value");
  }
  if (!decoder.map(*entries, 0, transform, Path(root, "map"), out)) {
    return false;
  }
  if (omitted != nullptr) {
    if (!is_count(*omitted)) {
      return decoder.fail(Path(root, "omitted"), "expected an integer >= 1");
    }
    if (entry_count(*out) < 64) {
      return decoder.fail(Path(root, "omitted"),
                          "only after the first 64 entries");
    }
    out->omitted = omitted->as_int();
  }
  return true;
}

EvidenceValue evidence_from_json(const Value& decoded) {
  EvidenceValue out;
  switch (decoded.kind()) {
    case Value::Kind::kNull:
      break;
    case Value::Kind::kBool:
      out.kind = EvidenceKind::kBool;
      out.boolean = decoded.as_bool();
      break;
    case Value::Kind::kInt:
      out.kind = EvidenceKind::kInt;
      out.integer = decoded.as_int();
      break;
    case Value::Kind::kDouble:
      out.kind = EvidenceKind::kDouble;
      out.number = decoded.as_double();
      break;
    case Value::Kind::kString:
      out.kind = EvidenceKind::kString;
      out.string = decoded.as_string();
      break;
    case Value::Kind::kArray:
      out.kind = EvidenceKind::kList;
      for (const Value& item : decoded.items()) {
        out.items.push_back(evidence_from_json(item));
      }
      break;
    case Value::Kind::kObject:
      out.kind = EvidenceKind::kMap;
      for (const Member& member : decoded.members()) {
        out.entries.push_back(
            EvidenceEntry{member.key, evidence_from_json(member.value), 0});
      }
      break;
  }
  return out;
}

}  // namespace engine
}  // namespace tugboat
