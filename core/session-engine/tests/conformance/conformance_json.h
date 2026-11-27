// The conformance runner's own small JSON reader and type-strict diff
// (conformance/README.md "Comparison"). It is independent of the engine's
// parser on purpose, so an engine parser bug cannot hide itself by being
// used on both sides of a comparison. Values keep their source span, so
// fixture inputs are submitted byte for byte as written.
#ifndef TUGBOAT_SESSION_ENGINE_TESTS_CONFORMANCE_JSON_H
#define TUGBOAT_SESSION_ENGINE_TESTS_CONFORMANCE_JSON_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace conformance {

struct Json {
  enum class Kind { kNull, kBool, kInt, kDouble, kString, kArray, kObject };
  Kind kind = Kind::kNull;
  bool boolean = false;
  std::string text;  // string value (UTF-8/WTF-8) or number lexeme
  std::vector<Json> items;
  std::vector<std::pair<std::string, Json>> members;
  size_t begin = 0;  // source span
  size_t end = 0;

  const Json* find(const std::string& key) const;
  bool is(Kind k) const { return kind == k; }
};

// Parses `text`; on failure returns false with a message in `*error`.
bool parse(const std::string& text, Json* out, std::string* error);

// The source text of `value` within `source`.
std::string source_of(const Json& value, const std::string& source);

bool int_equals(const Json* value, int64_t expected);

// Type-strict deep comparison: object key order is ignored; array order,
// absent versus null, and integer versus double are significant. Each
// difference becomes one line naming its JSON path.
class Diff {
 public:
  Diff(const std::string& expected_source, const std::string& actual_source)
      : expected_source_(expected_source), actual_source_(actual_source) {}

  void compare(const Json& expected, const Json& actual,
               const std::string& path);
  const std::vector<std::string>& lines() const { return lines_; }
  bool empty() const { return lines_.empty(); }
  void note(std::string line) { lines_.push_back(std::move(line)); }

 private:
  bool same_scalar(const Json& e, const Json& a) const;
  void mismatch(const std::string& path, const Json& expected,
                const Json& actual);

  const std::string& expected_source_;
  const std::string& actual_source_;
  std::vector<std::string> lines_;
};

}  // namespace conformance

#endif  // TUGBOAT_SESSION_ENGINE_TESTS_CONFORMANCE_JSON_H
