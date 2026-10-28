// Internal JSON model for the session engine. Not part of the C ABI.
//
// Matches Dart `dart:convert` semantics where the wire depends on them:
// - Integers and doubles stay distinct. A literal without fraction or
//   exponent that fits in int64 is an integer; every other number is a
//   double (as `jsonDecode` does, including integers beyond int64).
// - Doubles print in shortest round-trip form exactly like Dart
//   `double.toString()` (`390.0`, `1e+21`, `1.5e-7`, `-0.0`).
// - Strings are stored as WTF-8: UTF-8 that may also hold lone surrogates
//   (from `\uD800`-style escapes), because Dart strings are UTF-16 and keep
//   them. Raw input bytes must still be valid UTF-8.
// - Objects keep insertion order; `set` on an existing key replaces the value
//   in place, like assigning into a Dart `LinkedHashMap`.
#ifndef TUGBOAT_SESSION_ENGINE_JSON_H
#define TUGBOAT_SESSION_ENGINE_JSON_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace tugboat {
namespace engine {

struct Member;

class Value {
 public:
  enum class Kind { kNull, kBool, kInt, kDouble, kString, kArray, kObject };

  Value() = default;
  static Value null() { return Value(); }
  static Value boolean(bool v);
  static Value integer(int64_t v);
  static Value number(double v);
  static Value string(std::string v);
  static Value array();
  static Value object();

  Kind kind() const { return kind_; }
  bool is_null() const { return kind_ == Kind::kNull; }
  bool is_bool() const { return kind_ == Kind::kBool; }
  bool is_int() const { return kind_ == Kind::kInt; }
  bool is_double() const { return kind_ == Kind::kDouble; }
  bool is_number() const { return is_int() || is_double(); }
  bool is_string() const { return kind_ == Kind::kString; }
  bool is_array() const { return kind_ == Kind::kArray; }
  bool is_object() const { return kind_ == Kind::kObject; }

  bool as_bool() const { return bool_; }
  int64_t as_int() const { return int_; }
  double as_double() const { return double_; }
  // Integer or double as a double (Dart `num.toDouble()`).
  double to_double() const;
  const std::string& as_string() const { return string_; }

  const std::vector<Value>& items() const { return items_; }
  std::vector<Value>& items() { return items_; }
  const std::vector<Member>& members() const { return members_; }
  std::vector<Member>& members() { return members_; }

  // Object helpers. `find` returns nullptr when the key is absent.
  const Value* find(std::string_view key) const;
  // Replaces the value in place when `key` exists, else appends.
  void set(std::string_view key, Value value);
  void remove(std::string_view key);
  void push(Value value) { items_.push_back(std::move(value)); }

 private:
  Kind kind_ = Kind::kNull;
  bool bool_ = false;
  int64_t int_ = 0;
  double double_ = 0.0;
  std::string string_;
  std::vector<Value> items_;
  std::vector<Member> members_;
};

struct Member {
  std::string key;
  Value value;
};

struct ParseError {
  size_t offset = 0;
  std::string message;
};

// Strict RFC 8259 parser (the grammar Dart `jsonDecode` accepts). Rejects
// invalid UTF-8, nesting deeper than `max_depth`, and duplicate object keys.
bool parse_json(std::string_view text, uint32_t max_depth, Value* out,
                ParseError* error);

// Parser variations for text the engine decodes on Dart's behalf.
struct ParseOptions {
  uint32_t max_depth = 64;
  // Dart `jsonDecode`: a repeated key keeps its first position and takes the
  // last value, instead of being rejected.
  bool dart_duplicate_keys = false;
  // Accept WTF-8 lone surrogates in raw string content (text that came from
  // a Dart, Kotlin, or Swift string).
  bool wtf8 = false;
  // When non-zero, a container nested deeper than this is checked without
  // recursion and returned empty, and `max_depth` no longer applies to it.
  uint32_t build_depth = 0;
};

bool parse_json(std::string_view text, const ParseOptions& options,
                Value* out, ParseError* error);

// Compact JSON in insertion order, escaped like Dart `jsonEncode`. Fails
// (returning false and the JSON path in `error_path`) when a non-finite
// double would be written, as `jsonEncode` throws for those.
bool write_json(const Value& value, std::string* out, std::string* error_path);

// `jsonEncode` of a value known to be finite, such as anything built from
// state-changing input (which the dispatcher checks with `all_finite`).
std::string encode_json(const Value& value);

// Finds the first NaN or infinity in `value` (Dart's `jsonEncode` throws on
// them). Returns false and its JSON path, rooted at `path`, in `*bad_path`.
bool all_finite(const Value& value, const std::string& path,
                std::string* bad_path);

// Dart `double.toString()` for a finite double.
std::string format_double(double value);

// Dart `jsonEncode` of a string, including the quotes.
void write_json_string(std::string_view wtf8, std::string* out);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_JSON_H
