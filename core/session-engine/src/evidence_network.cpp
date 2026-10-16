// Dart `network_observer.dart` and `_finishNetworkCall`'s data
// (docs/evidence-messages.md section 3.2).
#include <algorithm>
#include <cmath>
#include <vector>

#include "evidence.h"
#include "evidence_value.h"
#include "name_table.h"
#include "text.h"

namespace tugboat {
namespace engine {

namespace {

using Limits = NetworkLimits;

constexpr NamedValue<NetworkOutcome> kOutcomes[] = {
    {"response", NetworkOutcome::kResponse},
    {"network_error", NetworkOutcome::kNetworkError},
    {"cancelled", NetworkOutcome::kCancelled},
};

// `jsonText` parsing: Dart's `jsonDecode` (repeated keys, lone surrogates,
// unbounded nesting). Containers below the depth normalization reads are
// checked and skipped: the root is parser depth 1, and a container at Dart
// depth 6 (parser depth 7) is unsupported whatever it holds.
ParseOptions json_text_options() {
  ParseOptions options;
  options.dart_duplicate_keys = true;
  options.wtf8 = true;
  options.build_depth = Limits::kMaxErrorResponseBodyDepth;
  options.max_depth = Limits::kMaxErrorResponseBodyDepth + 1;
  return options;
}

bool is_forbidden_route_rune(uint32_t rune) {
  return rune <= 0x20 || rune == 0x7f || rune == '%' || rune == '#' ||
         rune == '?' || rune == '\\';
}

// Collections on the path to the current value: what `ref` counts.
using Ancestors = std::vector<const EvidenceValue*>;

// Dart `_copyJsonValue`, stopped once the encoding of what it has kept
// passes the 4096-byte cap. The kept value is then encoded once.
class BodyNormalizer {
 public:
  // False when the root is unsupported (no body).
  bool run(const EvidenceValue& root, Value* out) {
    if (!supported(root, 0)) {
      return false;
    }
    Ancestors ancestors;
    *out = normalize(root, 0, &ancestors);
    return true;
  }

  bool over() const { return bytes_ > Limits::kMaxErrorResponseBodyBytes; }
  bool truncated() const { return truncated_; }

 private:
  // Whether Dart keeps `value` at `depth` (`ref`s are resolved first).
  static bool supported(const EvidenceValue& value, size_t depth) {
    switch (value.kind) {
      case EvidenceKind::kNull:
      case EvidenceKind::kBool:
      case EvidenceKind::kInt:
      case EvidenceKind::kString:
        return true;
      case EvidenceKind::kDouble:
        return std::isfinite(value.number);
      case EvidenceKind::kList:
      case EvidenceKind::kMap:
        return depth < Limits::kMaxErrorResponseBodyDepth;
      default:  // an iterable (Dart's `value is List` is false), unsupported
        return false;
    }
  }

  // Bytes of Dart's encoding of what has been kept so far. A closing bracket
  // counts when its collection ends, so once the count passes the cap the
  // kept prefix is exactly Dart's: encoding what was kept (its open
  // collections closed early) starts with the same 4096 bytes.
  void add(size_t bytes) { bytes_ += bytes; }

  // A child value: a `ref` resolves to the collection `n` levels up, which
  // is then traversed with its own ancestors (Dart has no cycle check here),
  // held in `resolved`. Any other child keeps `*ancestors`.
  struct Child {
    const EvidenceValue* value;
    Ancestors* ancestors;
  };

  static Child resolve(const EvidenceValue& value, Ancestors* ancestors,
                       Ancestors* resolved) {
    if (value.kind != EvidenceKind::kRef) {
      return Child{&value, ancestors};
    }
    const size_t index =
        ancestors->size() - static_cast<size_t>(value.integer);
    resolved->assign(ancestors->begin(),
                     ancestors->begin() + static_cast<long>(index));
    return Child{(*ancestors)[index], resolved};
  }

  Value normalize(const EvidenceValue& value, size_t depth,
                  Ancestors* ancestors) {
    Value out;
    switch (value.kind) {
      case EvidenceKind::kNull:
        break;
      case EvidenceKind::kBool:
        out = Value::boolean(value.boolean);
        break;
      case EvidenceKind::kInt:
        out = Value::integer(value.integer);
        break;
      case EvidenceKind::kDouble:
        out = Value::number(value.number);
        break;
      case EvidenceKind::kString:
        out = Value::string(value.string);
        break;
      case EvidenceKind::kMap:
        ancestors->push_back(&value);
        out = normalize_map(value, depth, ancestors);
        ancestors->pop_back();
        return out;
      default:  // kList (`supported` excludes everything else)
        ancestors->push_back(&value);
        out = normalize_list(value, depth, ancestors);
        ancestors->pop_back();
        return out;
    }
    add(encode_json(out).size());
    return out;
  }

  bool more_than_cap(int64_t sent, int64_t omitted) {
    return add_count(sent, omitted) >
           static_cast<int64_t>(Limits::kMaxErrorResponseBodyCollectionItems);
  }

  Value normalize_list(const EvidenceValue& list, size_t depth,
                       Ancestors* ancestors) {
    Value out = Value::array();
    add(1);  // [
    if (more_than_cap(static_cast<int64_t>(list.items.size()), list.omitted)) {
      truncated_ = true;
    }
    const size_t visit =
        std::min(list.items.size(), Limits::kMaxErrorResponseBodyCollectionItems);
    for (size_t i = 0; i < visit && !over(); ++i) {
      Ancestors resolved;
      const Child child = resolve(list.items[i], ancestors, &resolved);
      if (!supported(*child.value, depth + 1)) {
        truncated_ = true;
        continue;
      }
      add(out.items().empty() ? 0 : 1);  // ,
      out.push(normalize(*child.value, depth + 1, child.ancestors));
    }
    if (visit < Limits::kMaxErrorResponseBodyCollectionItems &&
        list.omitted > 0) {
      truncated_ = true;  // an omitted item within the cap: unsupported
    }
    add(1);  // ]
    return out;
  }

  Value normalize_map(const EvidenceValue& map, size_t depth,
                      Ancestors* ancestors) {
    Value out = Value::object();
    add(1);  // {
    if (more_than_cap(entry_count(map), map.omitted)) {
      truncated_ = true;
    }
    int64_t visited = 0;
    constexpr auto kCap =
        static_cast<int64_t>(Limits::kMaxErrorResponseBodyCollectionItems);
    for (const EvidenceEntry& entry : map.entries) {
      if (over()) {
        break;
      }
      if (visited >= kCap) {
        truncated_ = true;
        break;
      }
      if (entry.non_string_keys > 0) {
        // Each non-string key uses up one visit and sets `truncated`.
        visited += std::min(entry.non_string_keys, kCap - visited);
        truncated_ = true;
        continue;
      }
      visited += 1;
      Ancestors resolved;
      const Child child = resolve(entry.value, ancestors, &resolved);
      if (!supported(*child.value, depth + 1)) {
        truncated_ = true;
        continue;
      }
      // ,"key":  (body maps keep a repeated key, in order)
      add((out.members().empty() ? 0 : 1) +
          encode_json(Value::string(entry.key)).size() + 1);
      out.members().push_back(Member{
          entry.key, normalize(*child.value, depth + 1, child.ancestors)});
    }
    if (!over() && visited < kCap && map.omitted > 0) {
      truncated_ = true;  // omitted entries: unsupported values
    }
    add(1);  // }
    return out;
  }

  size_t bytes_ = 0;
  bool truncated_ = false;
};

ErrorBodySnapshot text_snapshot(const std::string& text) {
  ErrorBodySnapshot snapshot;
  snapshot.format = "text";
  const std::string_view prefix =
      utf8_prefix(text, Limits::kMaxErrorResponseBodyBytes);
  snapshot.truncated = prefix.size() != text.size();
  snapshot.value = Value::string(std::string(prefix));
  return snapshot;
}

std::optional<ErrorBodySnapshot> snapshot_value(const EvidenceValue& root) {
  if (root.kind == EvidenceKind::kNull) {
    return std::nullopt;
  }
  if (root.kind == EvidenceKind::kString) {
    return text_snapshot(root.string);
  }
  BodyNormalizer normalizer;
  Value normalized;
  if (!normalizer.run(root, &normalized)) {
    return std::nullopt;
  }
  ErrorBodySnapshot snapshot;
  snapshot.format = "json";
  if (!normalizer.over()) {
    snapshot.value = std::move(normalized);
    snapshot.truncated = normalizer.truncated();
    return snapshot;
  }
  // What was kept begins with the first 4096 bytes of Dart's encoding.
  const std::string encoded = encode_json(normalized);
  snapshot.value = Value::string(
      std::string(utf8_prefix(encoded, Limits::kMaxErrorResponseBodyBytes)));
  snapshot.representation = "serialized_prefix";
  snapshot.truncated = true;
  return snapshot;
}

Value capture_metadata(const ErrorBodySnapshot& snapshot) {
  Value out = Value::object();
  out.set("format", Value::string(snapshot.format));
  out.set("representation", Value::string(snapshot.representation));
  out.set("truncated", Value::boolean(snapshot.truncated));
  return out;
}

}  // namespace

std::optional<NetworkOutcome> parse_network_outcome(const std::string& name) {
  return parse_name(kOutcomes, name);
}

const char* network_outcome_name(NetworkOutcome outcome) {
  return name_of(kOutcomes, outcome);
}

std::optional<std::string> normalize_network_method(std::string_view method) {
  std::string trimmed(dart_trim(method));
  if (trimmed.empty() || trimmed.size() > Limits::kMaxMethodLength) {
    return std::nullopt;
  }
  for (char& c : trimmed) {
    if (static_cast<unsigned char>(c) >= 0x80) {
      return std::nullopt;
    }
    if (c >= 'a' && c <= 'z') {
      c = static_cast<char>(c - 'a' + 'A');
    }
  }
  return trimmed;
}

std::optional<std::string> normalize_network_route(std::string_view route) {
  const std::string_view trimmed = dart_trim(route);
  if (trimmed.empty() || trimmed.size() != route.size() ||
      utf16_longer_than(trimmed, Limits::kMaxRouteLength)) {
    return std::nullopt;
  }
  if (trimmed[0] != '/' || trimmed.substr(0, 2) == "//" ||
      trimmed.find("://") != std::string_view::npos) {
    return std::nullopt;
  }
  size_t i = 0;
  while (i < trimmed.size()) {
    if (is_forbidden_route_rune(wtf8_next(trimmed, &i))) {
      return std::nullopt;
    }
  }
  return std::string(trimmed);
}

std::optional<ErrorBodySnapshot> snapshot_error_body(const ErrorBody& body) {
  if (body.value) {
    return snapshot_value(*body.value);
  }
  if (body.json_text.empty()) {
    return std::nullopt;
  }
  Value decoded;
  ParseError error;
  if (!parse_json(body.json_text, json_text_options(), &decoded, &error)) {
    return text_snapshot(body.json_text);
  }
  return snapshot_value(evidence_from_json(decoded));
}

Value network_call_data(const NetworkCall& call, std::string method,
                        std::string route, int64_t duration_ms) {
  Value data = Value::object();
  data.set("method", Value::string(std::move(method)));
  data.set("route", Value::string(std::move(route)));
  if (call.status_code) {
    data.set("statusCode", Value::integer(*call.status_code));
  }
  data.set("outcome", Value::string(network_outcome_name(call.outcome)));
  data.set("durationMs", Value::integer(duration_ms));
  if (call.attempt_count && *call.attempt_count > 0) {
    data.set("attemptCount", Value::integer(*call.attempt_count));
  }
  if (call.error_body && call.status_code && *call.status_code >= 400) {
    std::optional<ErrorBodySnapshot> body = snapshot_error_body(*call.error_body);
    if (body) {
      Value capture = capture_metadata(*body);
      data.set("errorResponseBody", std::move(body->value));
      data.set("errorResponseBodyCapture", std::move(capture));
    }
  }
  return data;
}

}  // namespace engine
}  // namespace tugboat
