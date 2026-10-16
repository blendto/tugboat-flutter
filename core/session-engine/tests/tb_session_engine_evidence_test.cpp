// Unit tests for the evidence internals the fixtures cannot reach cheaply:
// Dart string helpers on WTF-8, `jsonDecode`-style repeated keys, and
// bounded work on pathological inputs (huge counts, exponential cycles).
// Behaviour itself is pinned by conformance/evidence/.
#include <chrono>
#include <string>

#include "dart_string.h"
#include "evidence.h"
#include "json.h"
#include "unit_support.h"

namespace {

using tugboat::engine::dart_trim;
using tugboat::engine::encode_json;
using tugboat::engine::ParseError;
using tugboat::engine::utf16_length;
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

void test_dart_strings() {
  const std::string emoji = "\xF0\x9F\x98\x80";  // U+1F600, 2 units
  CHECK(utf16_length("a" + emoji) == 3);
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

void test_json_decode_repeated_keys() {
  Value out;
  ParseError error;
  CHECK(tugboat::engine::parse_json_dart("{\"a\":1,\"b\":2,\"a\":{\"a\":3,\"a\":4}}",
                                         64, &out, &error));
  CHECK_EQ(encode_json(out), "{\"a\":{\"a\":4},\"b\":2}");
  CHECK(!tugboat::engine::parse_json("{\"a\":1,\"a\":2}", 64, &out, &error));
}

double seconds_for(const Value& body) {
  const auto start = std::chrono::steady_clock::now();
  tugboat::engine::snapshot_error_body(body);
  return std::chrono::duration<double>(std::chrono::steady_clock::now() -
                                       start)
      .count();
}

// 128 references to the enclosing list at every level would be 128^6 nodes
// in Dart; the engine stops once its encoding passes 4096 bytes.
void test_error_body_cycles_stay_bounded() {
  std::string refs;
  for (int i = 0; i < 128; ++i) {
    refs += std::string(i == 0 ? "" : ",") + "{\"ref\":1}";
  }
  const Value body = parse("{\"value\":[" + refs + "]}");
  const auto snapshot = tugboat::engine::snapshot_error_body(body);
  CHECK(snapshot && snapshot->representation == "serialized_prefix");
  CHECK(snapshot && snapshot->value.as_string().size() == 4096);
  CHECK(seconds_for(body) < 1.0);
}

void test_parameter_counts_stay_bounded() {
  const Value parameters = parse(
      "{\"map\":[[\"a\",{\"list\":[],\"omitted\":9223372036854775807}],"
      "[\"b\",{\"map\":[{\"nonStringKeys\":9223372036854775807}]}]]}");
  tugboat::engine::ParameterPolicy policy;
  const auto start = std::chrono::steady_clock::now();
  const auto data = tugboat::engine::external_event_data("e", std::nullopt,
                                                         policy, &parameters);
  CHECK(std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
            .count() < 1.0);
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
  test_json_decode_repeated_keys();
  test_error_body_cycles_stay_bounded();
  test_parameter_counts_stay_bounded();
  return unit::finish("evidence");
}
