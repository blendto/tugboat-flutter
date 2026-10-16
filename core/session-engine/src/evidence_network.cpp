// Dart `network_observer.dart` and `_finishNetworkCall`'s data
// (docs/evidence-messages.md section 3.2).
#include <cmath>
#include <vector>

#include "dart_string.h"
#include "evidence.h"
#include "evidence_value.h"

namespace tugboat {
namespace engine {

namespace {

using Limits = NetworkLimits;

// Nesting for `jsonText` bodies (TB_SESSION_ENGINE_MAX_DEPTH).
constexpr uint32_t kJsonTextMaxDepth = 512;

bool is_forbidden_route_rune(uint32_t rune) {
  return rune <= 0x20 || rune == 0x7f || rune == '%' || rune == '#' ||
         rune == '?' || rune == '\\';
}

// Collections on the encoded path to the current value: what `ref` counts.
using Path = std::vector<const Value*>;

// Dart `_copyJsonValue` and `jsonEncode` of its result in one pass, so a
// body is only normalized until its encoding passes the 4096-byte cap.
class BodyNormalizer {
 public:
  // Normalizes the root. False when it is unsupported (no body).
  bool run(const Node& root, Value* out) {
    if (!supported(root, 0)) {
      return false;
    }
    Path path;
    normalize(root, 0, &path, out);
    return true;
  }

  bool over() const { return over_; }
  bool truncated() const { return truncated_; }
  const std::string& encoded() const { return encoded_; }

 private:
  // What `ref` points at: the collection `n` levels up, with its own path.
  struct Resolved {
    Node node;
    Path path;
  };

  Resolved resolve(const Node& ref, const Path& path) const {
    const size_t index = path.size() - static_cast<size_t>(ref.ref());
    return Resolved{ref.child(*path[index]),
                    Path(path.begin(), path.begin() + static_cast<long>(index))};
  }

  // Whether Dart keeps the value (`supported`), decided before writing.
  bool supported(const Node& node, int64_t depth) const {
    switch (node.kind()) {
      case NodeKind::kNull:
      case NodeKind::kBool:
      case NodeKind::kInt:
      case NodeKind::kString:
        return true;
      case NodeKind::kDouble:
        return std::isfinite(node.number());
      case NodeKind::kList:
      case NodeKind::kMap:
        return depth < Limits::kMaxErrorResponseBodyDepth;
      case NodeKind::kRef:
        // A ref always names a list, map, or iterable. Iterables are never
        // supported, so look through to the target's kind.
        return depth < Limits::kMaxErrorResponseBodyDepth;
      case NodeKind::kIterable:
      case NodeKind::kUnsupported:
      case NodeKind::kDrop:
        return false;
    }
    return false;
  }

  void write(std::string_view text) {
    encoded_.append(text);
    if (encoded_.size() > Limits::kMaxErrorResponseBodyBytes) {
      over_ = true;
    }
  }

  // Writes and builds a supported value.
  void normalize(const Node& node, int64_t depth, Path* path, Value* out) {
    switch (node.kind()) {
      case NodeKind::kNull:
      case NodeKind::kBool:
      case NodeKind::kInt:
      case NodeKind::kString:
        *out = node.value();
        write(encode_json(*out));
        return;
      case NodeKind::kDouble:
        *out = Value::number(node.number());
        write(format_double(node.number()));
        return;
      case NodeKind::kRef: {
        Resolved target = resolve(node, *path);
        normalize_collection(target.node, depth, &target.path, out);
        return;
      }
      default:
        normalize_collection(node, depth, path, out);
        return;
    }
  }

  void normalize_collection(const Node& node, int64_t depth, Path* path,
                            Value* out) {
    if (node.kind() == NodeKind::kIterable) {
      // Only reachable through a ref; Dart's `value is List` is false.
      truncated_ = true;
      *out = Value::null();
      return;
    }
    path->push_back(&node.value());
    if (node.kind() == NodeKind::kMap) {
      normalize_map(node, depth, path, out);
    } else {
      normalize_list(node, depth, path, out);
    }
    path->pop_back();
  }

  bool more_than_cap(const Node& node, int64_t sent) {
    return add_count(sent, node.omitted()) >
           Limits::kMaxErrorResponseBodyCollectionItems;
  }

  void normalize_list(const Node& node, int64_t depth, Path* path,
                      Value* out) {
    *out = Value::array();
    write("[");
    if (more_than_cap(node, static_cast<int64_t>(node.size()))) {
      truncated_ = true;
    }
    const int64_t total = add_count(static_cast<int64_t>(node.size()),
                                    node.omitted());
    const int64_t visit =
        std::min(total, Limits::kMaxErrorResponseBodyCollectionItems);
    for (int64_t i = 0; i < visit && !over_; ++i) {
      if (static_cast<size_t>(i) >= node.size()) {
        truncated_ = true;  // an omitted item: unsupported
        break;
      }
      const Node item = node.item(static_cast<size_t>(i));
      if (!supported(item, depth + 1) || !target_supported(item, *path)) {
        truncated_ = true;
        continue;
      }
      if (!out->items().empty()) {
        write(",");
      }
      Value copied;
      normalize(item, depth + 1, path, &copied);
      out->push(std::move(copied));
    }
    write("]");
  }

  void normalize_map(const Node& node, int64_t depth, Path* path,
                     Value* out) {
    *out = Value::object();
    write("{");
    if (more_than_cap(node, entry_count(node))) {
      truncated_ = true;
    }
    int64_t visited = 0;
    for (size_t i = 0; i < node.size() && !over_; ++i) {
      if (visited >= Limits::kMaxErrorResponseBodyCollectionItems) {
        truncated_ = true;
        break;
      }
      const Entry entry = node.entry(i);
      if (entry.key == nullptr) {
        // Each non-string key uses up one visit and sets `truncated`.
        visited = add_count(
            visited,
            std::min(entry.run,
                     Limits::kMaxErrorResponseBodyCollectionItems - visited));
        truncated_ = true;
        continue;
      }
      visited += 1;
      const Node value = node.child(*entry.value);
      if (!supported(value, depth + 1) || !target_supported(value, *path)) {
        truncated_ = true;
        continue;
      }
      if (!out->members().empty()) {
        write(",");
      }
      std::string key;
      write_json_string(*entry.key, &key);
      key.push_back(':');
      write(key);
      Value copied;
      normalize(value, depth + 1, path, &copied);
      out->set(*entry.key, std::move(copied));
    }
    if (!over_ && visited < Limits::kMaxErrorResponseBodyCollectionItems &&
        node.omitted() > 0) {
      truncated_ = true;  // omitted entries: unsupported values
    }
    write("}");
  }

  // A ref is supported only when its target is a list or map.
  bool target_supported(const Node& node, const Path& path) const {
    if (node.kind() != NodeKind::kRef) {
      return true;
    }
    return resolve(node, path).node.kind() != NodeKind::kIterable;
  }

  std::string encoded_;
  bool over_ = false;
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

std::optional<ErrorBodySnapshot> snapshot_node(const Node& root) {
  if (root.kind() == NodeKind::kNull) {
    return std::nullopt;
  }
  if (root.kind() == NodeKind::kString) {
    return text_snapshot(root.value().as_string());
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
  snapshot.value = Value::string(std::string(
      utf8_prefix(normalizer.encoded(), Limits::kMaxErrorResponseBodyBytes)));
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

std::optional<ErrorBodySnapshot> snapshot_error_body(const Value& body) {
  if (const Value* value = body.find("value")) {
    return snapshot_node(Node::encoded(*value));
  }
  const std::string& text = body.find("jsonText")->as_string();
  if (text.empty()) {
    return std::nullopt;
  }
  Value decoded;
  ParseError error;
  if (!parse_json_dart(text, kJsonTextMaxDepth, &decoded, &error)) {
    return text_snapshot(text);
  }
  return snapshot_node(Node::plain(decoded));
}

Value network_call_data(const NetworkCall& call) {
  Value data = Value::object();
  data.set("method", Value::string(call.method));
  data.set("route", Value::string(call.route));
  if (call.status_code) {
    data.set("statusCode", Value::integer(*call.status_code));
  }
  data.set("outcome", Value::string(call.outcome));
  data.set("durationMs", Value::integer(call.duration_ms));
  if (call.attempt_count && *call.attempt_count > 0) {
    data.set("attemptCount", Value::integer(*call.attempt_count));
  }
  if (call.error_body != nullptr && call.status_code &&
      *call.status_code >= 400) {
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
