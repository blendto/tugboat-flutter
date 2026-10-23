// Unit tests for the evidence internals the fixtures cannot reach cheaply:
// Dart string helpers on WTF-8, the `jsonDecode` parser options, and
// bounded work on pathological inputs (huge counts, exponential cycles).
// Behaviour itself is pinned by conformance/evidence/.
#include <chrono>
#include <string>

#include "evidence.h"
#include "evidence_value.h"
#include "json.h"
#include "text.h"
#include "unit_support.h"

namespace {

using tugboat::engine::dart_trim;
using tugboat::engine::encode_json;
using tugboat::engine::ErrorBody;
using tugboat::engine::Error;
using tugboat::engine::EvidenceContext;
using tugboat::engine::EvidenceValue;
using tugboat::engine::ParseError;
using tugboat::engine::ParseOptions;
using tugboat::engine::utf16_longer_than;
using tugboat::engine::utf16_prefix;
using tugboat::engine::utf8_prefix;
using tugboat::engine::Value;

Value parse(const std::string& text) {
  Value out;
  ParseError error;
  CHECK(tugboat::engine::parse_json(text, 64, &out, &error));
  return out;
}

double seconds_since(std::chrono::steady_clock::time_point start) {
  return std::chrono::duration<double>(std::chrono::steady_clock::now() -
                                       start)
      .count();
}

void test_dart_strings() {
  const std::string emoji = "\xF0\x9F\x98\x80";  // U+1F600, 2 units
  CHECK(utf16_longer_than("a" + emoji, 2));
  CHECK(!utf16_longer_than("a" + emoji, 3));
  // A cut inside the pair keeps the high surrogate (WTF-8 ED A0 BD).
  CHECK_EQ(encode_json(Value::string(utf16_prefix("a" + emoji, 2))),
           "\"a\\ud83d\"");
  CHECK_EQ(utf16_prefix("a" + emoji, 3), "a" + emoji);
  CHECK_EQ(std::string(dart_trim("\xC2\xA0 x y\xEF\xBB\xBF\t")), "x y");
  CHECK_EQ(std::string(dart_trim("\xE2\x80\x8B")), "\xE2\x80\x8B");  // ZWSP
  CHECK(dart_trim(" \xE3\x80\x80").empty());
  CHECK_EQ(std::string(utf8_prefix("ab\xC3\xA9", 3)), "ab");
}

void test_parse_options() {
  Value out;
  ParseError error;
  ParseOptions dart;
  dart.dart_duplicate_keys = true;
  CHECK(tugboat::engine::parse_json(
      "{\"a\":1,\"b\":2,\"a\":{\"a\":3,\"a\":4}}", dart, &out, &error));
  CHECK_EQ(encode_json(out), "{\"a\":{\"a\":4},\"b\":2}");
  CHECK(!tugboat::engine::parse_json("{\"a\":1,\"a\":2}", 64, &out, &error));

  // Raw WTF-8 lone surrogates only with `wtf8`.
  const std::string lone = "[\"\xED\xA0\x80\"]";
  CHECK(!tugboat::engine::parse_json(lone, 64, &out, &error));
  ParseOptions wtf8;
  wtf8.wtf8 = true;
  CHECK(tugboat::engine::parse_json(lone, wtf8, &out, &error));
  CHECK_EQ(encode_json(out), "[\"\\ud800\"]");

  // Below `build_depth`, containers are checked iteratively and come back
  // empty, at any nesting.
  ParseOptions shallow;
  shallow.build_depth = 2;
  shallow.max_depth = 3;
  const std::string deep = std::string(100000, '[') + "{\"k\":[1,\"]\"]}" +
                           std::string(100000, ']');
  CHECK(tugboat::engine::parse_json("[" + deep + ",7]", shallow, &out,
                                    &error));
  CHECK_EQ(encode_json(out), "[[[]],7]");
  CHECK(!tugboat::engine::parse_json(
      "[" + std::string(1000, '[') + "1,]" + std::string(999, ']') + "]",
      shallow, &out, &error));
  CHECK(!tugboat::engine::parse_json("[[[{\"k\" 1}]]]", shallow, &out,
                                     &error));
}

// 128 references to the enclosing list at every level would be 128^6 nodes
// in Dart; the engine stops once its encoding passes 4096 bytes.
void test_error_body_cycles_stay_bounded() {
  std::string refs;
  for (int i = 0; i < 128; ++i) {
    refs += std::string(i == 0 ? "" : ",") + "{\"ref\":1}";
  }
  ErrorBody body;
  body.value.emplace();
  Error error;
  CHECK(tugboat::engine::decode_evidence_value(
      parse("[" + refs + "]"), EvidenceContext::kErrorBody, "$", &*body.value,
      &error));
  const auto start = std::chrono::steady_clock::now();
  const auto snapshot = tugboat::engine::snapshot_error_body(body);
  CHECK(seconds_since(start) < 1.0);
  CHECK(snapshot && snapshot->representation == "serialized_prefix");
  CHECK(snapshot && snapshot->value.as_string().size() == 4096);
}

void test_parameter_counts_stay_bounded() {
  EvidenceValue parameters;
  Error error;
  CHECK(tugboat::engine::decode_parameters_map(
      parse("{\"map\":[[\"a\",{\"list\":[],\"omitted\":9223372036854775807}],"
            "[\"b\",{\"map\":[{\"nonStringKeys\":9223372036854775807}]}]]}"),
      false, "$", &parameters, &error));
  tugboat::engine::ParameterPolicy policy;
  const auto start = std::chrono::steady_clock::now();
  const auto data = tugboat::engine::external_event_data("e", std::nullopt,
                                                         policy, &parameters);
  CHECK(seconds_since(start) < 1.0);
  CHECK(data.has_value());
  // 257 stand-in items (256 dropped plus the one over budget), then a
  // saturated count.
  CHECK_EQ(encode_json(*data->find("capture")),
           "{\"values\":\"allow_all\",\"truncated\":true,"
           "\"droppedCount\":9223372036854775807}");
}

}  // namespace

int main() {
  test_dart_strings();
  test_parse_options();
  test_error_body_cycles_stay_bounded();
  test_parameter_counts_stay_bounded();
  return unit::finish("evidence");
}
