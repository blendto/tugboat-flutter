// Unit tests for the session engine: number formatting, SHA-256, UTF-16
// ordering, Dart DateTime formatting, and C ABI error paths. Fixture
// conformance lives in tb_session_engine_conformance.cpp.
//
// Expected values marked "Dart" were produced by the Dart SDK (3.13.4):
// jsonEncode(jsonDecode(lexeme)), DateTime.toIso8601String(), and
// String.compareTo. SHA-256 vectors are FIPS 180-4 / NIST examples.
#include "tugboat/tb_session_engine.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "dart_time.h"
#include "json.h"
#include "text.h"

namespace {

int g_failures = 0;

void check(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::fprintf(stderr, "FAIL %s:%d %s\n", file, line, expr);
    ++g_failures;
  }
}

void check_eq(const std::string& actual, const std::string& expected,
              const char* expr, const char* file, int line) {
  if (actual != expected) {
    std::fprintf(stderr, "FAIL %s:%d %s\n  expected: %s\n  actual:   %s\n",
                 file, line, expr, expected.c_str(), actual.c_str());
    ++g_failures;
  }
}

#define CHECK(cond) check(static_cast<bool>(cond), #cond, __FILE__, __LINE__)
#define CHECK_EQ(actual, expected) \
  check_eq((actual), (expected), #actual, __FILE__, __LINE__)

using tugboat::engine::Value;

// ------------------------------------------------------------ JSON numbers

// "<i|d>:<jsonEncode output>" for a JSON number lexeme, or "error".
std::string round_trip(const std::string& lexeme) {
  Value value;
  tugboat::engine::ParseError error;
  if (!tugboat::engine::parse_json(lexeme, 64, &value, &error)) {
    return "error";
  }
  std::string out;
  if (!tugboat::engine::write_json(value, &out, nullptr)) {
    return "unencodable";
  }
  return std::string(value.is_int() ? "i:" : "d:") + out;
}

void test_number_round_trip() {
  struct Case {
    const char* lexeme;
    const char* dart;
  };
  const Case cases[] = {
      // Integer vs double typing (Dart jsonDecode).
      {"0", "i:0"},
      {"-0", "i:0"},
      {"0.0", "d:0.0"},
      {"-0.0", "d:-0.0"},
      {"100", "i:100"},
      {"390.0", "d:390.0"},
      {"1e2", "d:100.0"},
      {"1E+2", "d:100.0"},
      {"9223372036854775807", "i:9223372036854775807"},
      {"-9223372036854775808", "i:-9223372036854775808"},
      {"9223372036854775808", "d:9223372036854776000.0"},
      {"-9223372036854775809", "d:-9223372036854776000.0"},
      {"123456789012345678901234567890", "d:1.2345678901234568e+29"},
      // Decimal vs exponential thresholds (Dart double.toString).
      {"1e20", "d:100000000000000000000.0"},
      {"1e21", "d:1e+21"},
      {"1e-6", "d:0.000001"},
      {"1e-7", "d:1e-7"},
      {"2.5e-5", "d:0.000025"},
      {"123e-20", "d:1.23e-18"},
      // Shortest round trip and correct rounding at the extremes.
      {"0.1", "d:0.1"},
      {"-0.6000000000000001", "d:-0.6000000000000001"},
      {"1.0000000000000002", "d:1.0000000000000002"},
      {"5e-324", "d:5e-324"},
      {"4.9406564584124654e-324", "d:5e-324"},
      {"1e-400", "d:0.0"},
      {"2.2250738585072011e-308", "d:2.225073858507201e-308"},
      {"1.7976931348623158e308", "d:1.7976931348623157e+308"},
      // Random vectors from the Dart differential run.
      {"-1.392605397534108e-37", "d:-1.392605397534108e-37"},
      {"0.21600000000000008", "d:0.21600000000000008"},
      {"-1.2526975322227872e-276", "d:-1.2526975322227872e-276"},
      {"5.189616746e-86", "d:5.189616746e-86"},
      {"1.3275952514135694e+268", "d:1.3275952514135694e+268"},
      {"-897168.00295781389576076e-165", "d:-8.97168002957814e-160"},
      {"294569209336.606334800", "d:294569209336.6063"},
      {"-0.42599999999999993", "d:-0.42599999999999993"},
      // Overflow parses (as in Dart) but cannot be encoded.
      {"1e400", "unencodable"},
      {"-1e400", "unencodable"},
      // Grammar errors.
      {"01", "error"},
      {"1.", "error"},
      {".5", "error"},
      {"+1", "error"},
      {"1e", "error"},
      {"-", "error"},
      {"NaN", "error"},
      {"Infinity", "error"},
  };
  for (const Case& c : cases) {
    CHECK_EQ(round_trip(c.lexeme), std::string(c.dart));
  }
}

void test_format_double() {
  CHECK_EQ(tugboat::engine::format_double(390.0), std::string("390.0"));
  CHECK_EQ(tugboat::engine::format_double(-0.0), std::string("-0.0"));
  CHECK_EQ(tugboat::engine::format_double(0.2 - 0.8),
           std::string("-0.6000000000000001"));
  CHECK_EQ(tugboat::engine::format_double(1.5e300), std::string("1.5e+300"));
  CHECK_EQ(tugboat::engine::format_double(1.5e-7), std::string("1.5e-7"));
  CHECK_EQ(tugboat::engine::format_double(2.625), std::string("2.625"));
}

// --------------------------------------------------------- JSON structure

bool parses(const std::string& text, uint32_t depth = 64) {
  Value value;
  tugboat::engine::ParseError error;
  return tugboat::engine::parse_json(text, depth, &value, &error);
}

void test_parse_grammar() {
  CHECK(parses(" {\"a\" : [1, 2.5, \"x\", true, false, null]} "));
  CHECK(!parses("[1,]"));
  CHECK(!parses("{\"a\":1,}"));
  CHECK(!parses("{'a':1}"));
  CHECK(!parses("[1] x"));
  CHECK(!parses(""));
  CHECK(!parses("nul"));
  CHECK(!parses("\"a\tb\""));                // raw control character
  CHECK(!parses("\"\\x\""));                 // bad escape
  CHECK(!parses("\"\\u12g4\""));             // bad hex
  CHECK(!parses("\"\xC3\""));                // truncated UTF-8
  CHECK(!parses("\"\xC0\xAF\""));            // overlong
  CHECK(!parses("\"\xED\xA0\x80\""));        // raw surrogate bytes
  CHECK(!parses("\"\xF4\x90\x80\x80\""));    // above U+10FFFF
  CHECK(parses("\"\xF0\x9F\x98\x80\""));     // U+1F600
  CHECK(!parses("{\"a\":1,\"a\":2}"));       // duplicate key
  CHECK(parses("[[[1]]]", 3));
  CHECK(!parses("[[[1]]]", 2));
  CHECK(!parses(std::string(10000, '['), 512));  // no stack overflow
}

std::string reencode(const std::string& text) {
  Value value;
  tugboat::engine::ParseError error;
  if (!tugboat::engine::parse_json(text, 64, &value, &error)) {
    return "error";
  }
  std::string out;
  tugboat::engine::write_json(value, &out, nullptr);
  return out;
}

void test_string_escaping() {
  // Dart jsonEncode: short escapes, \u00XX for other controls, lowercase hex,
  // '/' and DEL raw, U+2028 raw, lone surrogates escaped, pairs raw.
  CHECK_EQ(reencode("\"\\u0001\\u001f\\b\\f\\n\\r\\t\\\"\\\\\\/\\u007f\""),
           std::string("\"\\u0001\\u001f\\b\\f\\n\\r\\t\\\"\\\\/\x7f\""));
  CHECK_EQ(reencode("\"\\u2028\""), std::string("\"\xE2\x80\xA8\""));
  CHECK_EQ(reencode("\"\\ud800x\""), std::string("\"\\ud800x\""));
  CHECK_EQ(reencode("\"\\uDC00\\uD800\""), std::string("\"\\udc00\\ud800\""));
  CHECK_EQ(reencode("\"\\ud83d\\ude00\""), std::string("\"\xF0\x9F\x98\x80\""));
  CHECK_EQ(reencode("\"\\u00e9\""), std::string("\"\xC3\xA9\""));
  // Insertion order kept; nested arrays and objects compact.
  CHECK_EQ(reencode("{ \"b\": [1, {\"a\": null}], \"a\": true }"),
           std::string("{\"b\":[1,{\"a\":null}],\"a\":true}"));
}

void test_object_set_semantics() {
  // Dart map literal `{...data, 'k': v}`: an existing key keeps its position.
  Value object = Value::object();
  object.set("relatedEventId", Value::string("x"));
  object.set("a", Value::integer(1));
  object.set("relatedEventId", Value::string("y"));
  std::string out;
  tugboat::engine::write_json(object, &out, nullptr);
  CHECK_EQ(out, std::string("{\"relatedEventId\":\"y\",\"a\":1}"));
  object.remove("relatedEventId");
  object.set("relatedEventId", Value::string("z"));
  out.clear();
  tugboat::engine::write_json(object, &out, nullptr);
  CHECK_EQ(out, std::string("{\"a\":1,\"relatedEventId\":\"z\"}"));
}

// ------------------------------------------------------------- SHA-256

void test_sha256() {
  using tugboat::engine::sha256_hex;
  CHECK_EQ(sha256_hex(""),
           std::string("e3b0c44298fc1c149afbf4c8996fb924"
                       "27ae41e4649b934ca495991b7852b855"));
  CHECK_EQ(sha256_hex("abc"),
           std::string("ba7816bf8f01cfea414140de5dae2223"
                       "b00361a396177a9cb410ff61f20015ad"));
  CHECK_EQ(sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
           std::string("248d6a61d20638b8e5c026930c3e6039"
                       "a33ce45964ff2167f6ecedd419db06c1"));
  // Padding boundaries: 55, 56, and 64 bytes.
  CHECK_EQ(sha256_hex(std::string(55, 'a')),
           std::string("9f4390f8d30c2dd92ec9f095b65e2b9a"
                       "e9b0a925a5258e241c9f1e910f734318"));
  CHECK_EQ(sha256_hex(std::string(56, 'a')),
           std::string("b35439a4ac6f0948b6d6f9e3c6af0f5f"
                       "590ce20f1bde7090ef7970686ec6738a"));
  CHECK_EQ(sha256_hex(std::string(64, 'a')),
           std::string("ffe054fe7ae0cb6dc65c3af9b61d5209"
                       "f439851db43d0ba5997337df154668eb"));
  CHECK_EQ(sha256_hex(std::string(1000000, 'a')),
           std::string("cdc76e5c9914fb9281a1c7e284d73e67"
                       "f1809a48a497200e046d39ccc7112cd0"));
}

void test_label_hash() {
  using tugboat::engine::label_hash;
  CHECK_EQ(label_hash(""), std::string(""));
  CHECK_EQ(label_hash("abc"), std::string("ba7816bf8f01cfea"));
  // Dart utf8.encode turns lone surrogates into U+FFFD before hashing.
  const std::string lone_high = "\xED\xA0\x80";  // WTF-8 U+D800
  CHECK_EQ(label_hash(lone_high), std::string("83d544ccc223c057"));
  CHECK_EQ(label_hash("a\xED\xB0\x80\xED\xA0\xBD"),  // a, U+DC00, U+D83D
           std::string("0b4100658d8f540c"));
  CHECK_EQ(tugboat::engine::wtf8_to_utf8("a\xED\xA0\x80" "b"),
           std::string("a\xEF\xBF\xBD" "b"));
}

// ----------------------------------------------------------- UTF-16 order

void test_compare_utf16() {
  using tugboat::engine::compare_utf16;
  CHECK(compare_utf16("", "") == 0);
  CHECK(compare_utf16("", "a") < 0);
  CHECK(compare_utf16("a", "ab") < 0);
  CHECK(compare_utf16("B", "a") < 0);
  CHECK(compare_utf16("10", "9") < 0);
  // U+1F600 (D83D DE00) sorts before U+FF5A in UTF-16 but after it in UTF-8.
  const std::string astral = "\xF0\x9F\x98\x80";
  const std::string bmp_high = "\xEF\xBD\x9A";
  CHECK(compare_utf16(astral, bmp_high) < 0);
  CHECK(compare_utf16(bmp_high, astral) > 0);
  CHECK(std::string(astral) > bmp_high);  // byte order disagrees
  // A lone high surrogate D83D is a prefix of U+1F600's encoding.
  CHECK(compare_utf16("\xED\xA0\xBD", astral) < 0);
  // U+E000 vs U+10000 (D800 DC00): UTF-16 puts the astral one first.
  CHECK(compare_utf16("\xEE\x80\x80", "\xF0\x90\x80\x80") > 0);
  CHECK(compare_utf16(astral, astral) == 0);
}

// ------------------------------------------------------------ Dart time

std::string iso(int64_t start_ms, int64_t at_ms) {
  int64_t micros = 0;
  if (!tugboat::engine::dart_add_ms(start_ms, at_ms, &micros)) {
    return "ERROR";
  }
  return tugboat::engine::dart_iso8601_utc(micros);
}

void test_dart_time() {
  // Dart: DateTime.fromMillisecondsSinceEpoch(start, isUtc: true)
  //   .add(Duration(milliseconds: at)).toIso8601String()
  CHECK_EQ(iso(1781827200000, 55957), std::string("2026-06-19T00:00:55.957Z"));
  CHECK_EQ(iso(0, -1), std::string("1969-12-31T23:59:59.999Z"));
  CHECK_EQ(iso(951782400000, 0), std::string("2000-02-29T00:00:00.000Z"));
  CHECK_EQ(iso(-62167219200000, -1), std::string("-0001-12-31T23:59:59.999Z"));
  CHECK_EQ(iso(-62135596800001, 0), std::string("0000-12-31T23:59:59.999Z"));
  CHECK_EQ(iso(253402300799999, 1), std::string("+010000-01-01T00:00:00.000Z"));
  CHECK_EQ(iso(-377705116800000, -1),
           std::string("-010000-12-31T23:59:59.999Z"));
  CHECK_EQ(iso(8640000000000000, 0), std::string("+275760-09-13T00:00:00.000Z"));
  CHECK_EQ(iso(-8640000000000000, 0),
           std::string("-271821-04-20T00:00:00.000Z"));
  CHECK_EQ(iso(8640000000000000, 1), std::string("ERROR"));
  CHECK_EQ(iso(-8640000000000000, -1), std::string("ERROR"));
  CHECK_EQ(iso(8640000000000001, 0), std::string("ERROR"));
  // Dart VM wraps `at * 1000`; these are what Dart really produces.
  CHECK_EQ(iso(1781827200000, 18446744073709552),
           std::string("2026-06-19T00:00:00.000384Z"));
  CHECK_EQ(iso(0, INT64_MIN), std::string("1970-01-01T00:00:00.000Z"));
  CHECK_EQ(iso(0, 9223372036854775), std::string("ERROR"));
}

// ---------------------------------------------------------------- C ABI

tb_session_engine* make_engine(uint32_t max_depth = 0,
                               size_t max_message_bytes = 0) {
  tb_session_engine_config_v1 config{};
  config.abi_version = TB_SESSION_ENGINE_ABI_VERSION;
  config.max_depth = max_depth;
  config.max_message_bytes = max_message_bytes;
  tb_session_engine* engine = nullptr;
  if (tb_session_engine_create_v1(&config, &engine) != TB_SESSION_OK) {
    return nullptr;
  }
  return engine;
}

struct Response {
  tb_session_status status;
  std::string json;
};

Response submit(tb_session_engine* engine, const std::string& message) {
  const char* out = nullptr;
  size_t len = 0;
  const tb_session_status status = tb_session_engine_submit_v1(
      engine, message.data(), message.size(), &out, &len);
  Response response{status, std::string()};
  if (out != nullptr) {
    response.json.assign(out, len);
  }
  return response;
}

bool contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

void test_version_queries() {
  CHECK(std::strcmp(tb_session_engine_version(), "0.1.0") == 0);
  CHECK(tb_session_engine_abi_version() == TB_SESSION_ENGINE_ABI_VERSION);
  CHECK(tb_session_engine_session_schema_version() == 10);
  CHECK(tb_session_engine_fingerprint_schema_version() == 6);
  CHECK(std::strcmp(tb_session_status_name(TB_SESSION_OK), "ok") == 0);
  CHECK(std::strcmp(tb_session_status_name(TB_SESSION_INVALID_MESSAGE),
                    "invalid_message") == 0);
  CHECK(std::strcmp(tb_session_status_name(static_cast<tb_session_status>(99)),
                    "unknown") == 0);
}

void test_create_errors() {
  tb_session_engine_config_v1 config{};
  config.abi_version = TB_SESSION_ENGINE_ABI_VERSION;
  tb_session_engine* engine = reinterpret_cast<tb_session_engine*>(0x1);

  CHECK(tb_session_engine_create_v1(&config, nullptr) ==
        TB_SESSION_INVALID_ARGUMENT);
  CHECK(tb_session_engine_create_v1(nullptr, &engine) ==
        TB_SESSION_INVALID_ARGUMENT);
  CHECK(engine == nullptr);

  config.abi_version = TB_SESSION_ENGINE_ABI_VERSION + 1;
  engine = reinterpret_cast<tb_session_engine*>(0x1);
  CHECK(tb_session_engine_create_v1(&config, &engine) ==
        TB_SESSION_ABI_MISMATCH);
  CHECK(engine == nullptr);

  config.abi_version = TB_SESSION_ENGINE_ABI_VERSION;
  config.max_depth = TB_SESSION_ENGINE_MAX_DEPTH + 1;
  CHECK(tb_session_engine_create_v1(&config, &engine) ==
        TB_SESSION_INVALID_ARGUMENT);
  config.max_depth = 0;
  config.max_message_bytes = TB_SESSION_ENGINE_MAX_MESSAGE_BYTES + 1;
  CHECK(tb_session_engine_create_v1(&config, &engine) ==
        TB_SESSION_INVALID_ARGUMENT);

  config.max_message_bytes = 0;
  CHECK(tb_session_engine_create_v1(&config, &engine) == TB_SESSION_OK);
  CHECK(engine != nullptr);
  tb_session_engine_destroy(engine);
  tb_session_engine_destroy(nullptr);  // no-op
}

void test_submit_null_arguments() {
  tb_session_engine* engine = make_engine();
  const char* out = reinterpret_cast<const char*>(0x1);
  size_t len = 7;
  const std::string msg = "{}";

  CHECK(tb_session_engine_submit_v1(nullptr, msg.data(), msg.size(), &out,
                                    &len) == TB_SESSION_INVALID_ARGUMENT);
  CHECK(out == nullptr && len == 0);
  len = 7;
  CHECK(tb_session_engine_submit_v1(engine, msg.data(), msg.size(), nullptr,
                                    &len) == TB_SESSION_INVALID_ARGUMENT);
  CHECK(len == 0);
  out = reinterpret_cast<const char*>(0x1);
  CHECK(tb_session_engine_submit_v1(engine, msg.data(), msg.size(), &out,
                                    nullptr) == TB_SESSION_INVALID_ARGUMENT);
  CHECK(out == nullptr);

  // NULL message with a length: invalid argument, but still an error doc.
  CHECK(tb_session_engine_submit_v1(engine, nullptr, 3, &out, &len) ==
        TB_SESSION_INVALID_ARGUMENT);
  CHECK(out != nullptr && contains(std::string(out, len), "invalid_argument"));
  // NULL message of length 0 is an empty message.
  CHECK(tb_session_engine_submit_v1(engine, nullptr, 0, &out, &len) ==
        TB_SESSION_MALFORMED_MESSAGE);
  CHECK(out != nullptr && out[len] == '\0');
  tb_session_engine_destroy(engine);
}

const char kHost[] =
    "{\"app\":{\"name\":\"a\",\"version\":\"1\",\"buildNumber\":\"1\","
    "\"installationId\":\"i\",\"appId\":\"x\"},\"device\":{\"id\":\"d\","
    "\"platform\":\"android\",\"screenSize\":{\"width\":1,\"height\":1},"
    "\"screenDensity\":1,\"screenDpi\":1,\"screenPixelDensity\":1},"
    "\"ip\":{\"ip\":\"0\"},\"locale\":{}}";

std::string event_message(const std::string& session,
                          const std::string& event) {
  return std::string("{\"type\":\"collector.event\",\"input\":{\"host\":") +
         kHost + ",\"session\":" + session + ",\"event\":" + event + "}}";
}

std::string lifecycle_message(const std::string& session,
                              const std::string& lifecycle) {
  return std::string(
             "{\"type\":\"collector.sessionLifecycle\",\"input\":{\"host\":") +
         kHost + ",\"session\":" + session + ",\"lifecycle\":" + lifecycle +
         "}}";
}

const char kSession[] = "{\"sessionId\":\"s\",\"startedAtEpochMs\":0}";
const char kEvent[] =
    "{\"id\":\"e\",\"atMs\":1,\"type\":\"probe\",\"stream\":\"evidence\"}";

void expect_status(tb_session_engine* engine, const std::string& message,
                   tb_session_status status, const std::string& needle,
                   int line) {
  const Response r = submit(engine, message);
  const bool ok = r.status == status && contains(r.json, needle) &&
                  contains(r.json, tb_session_status_name(status));
  if (!ok) {
    std::fprintf(stderr,
                 "FAIL %s:%d expected %s containing %s\n  got %s: %s\n",
                 __FILE__, line, tb_session_status_name(status),
                 needle.c_str(), tb_session_status_name(r.status),
                 r.json.c_str());
    ++g_failures;
  }
}

#define EXPECT_STATUS(message, status, needle) \
  expect_status(engine, (message), (status), (needle), __LINE__)

void test_submit_errors() {
  tb_session_engine* engine = make_engine();
  // Malformed: offset reported.
  EXPECT_STATUS("{\"type\":", TB_SESSION_MALFORMED_MESSAGE, "\"offset\":8");
  EXPECT_STATUS("not json", TB_SESSION_MALFORMED_MESSAGE, "offset");
  EXPECT_STATUS(std::string("\"\xFF\""), TB_SESSION_MALFORMED_MESSAGE,
                "invalid UTF-8");
  EXPECT_STATUS("{\"type\":\"a\",\"type\":\"b\"}",
                TB_SESSION_MALFORMED_MESSAGE, "duplicate object key");
  // Envelope.
  EXPECT_STATUS("[]", TB_SESSION_INVALID_MESSAGE, "expected object");
  EXPECT_STATUS("{\"input\":{}}", TB_SESSION_INVALID_MESSAGE, "$.type");
  EXPECT_STATUS("{\"type\":\"fingerprint.labelHash\"}",
                TB_SESSION_INVALID_MESSAGE, "$.input");
  EXPECT_STATUS("{\"type\":\"fingerprint.labelHash\",\"input\":{\"value\":"
                "\"a\"},\"extra\":1}",
                TB_SESSION_INVALID_MESSAGE, "$.extra");
  EXPECT_STATUS("{\"type\":\"session.pointerDown\",\"input\":{}}",
                TB_SESSION_UNSUPPORTED_MESSAGE, "$.type");
  EXPECT_STATUS("{\"type\":\"fingerprint.labelHash\",\"contract\":{"
                "\"sessionSchemaVersion\":11,\"fingerprintSchemaVersion\":6},"
                "\"input\":{\"value\":\"a\"}}",
                TB_SESSION_CONTRACT_MISMATCH, "sessionSchemaVersion 10");
  EXPECT_STATUS("{\"type\":\"fingerprint.labelHash\",\"contract\":{"
                "\"sessionSchemaVersion\":10},\"input\":{\"value\":\"a\"}}",
                TB_SESSION_INVALID_MESSAGE, "fingerprintSchemaVersion");
  // Unknown keys and wrong types at every level.
  EXPECT_STATUS("{\"type\":\"fingerprint.labelHash\",\"input\":{\"value\":"
                "\"a\",\"salt\":\"b\"}}",
                TB_SESSION_INVALID_MESSAGE, "$.input.salt");
  EXPECT_STATUS("{\"type\":\"fingerprint.labelHash\",\"input\":{\"value\":1}}",
                TB_SESSION_INVALID_MESSAGE, "expected string");
  EXPECT_STATUS("{\"type\":\"fingerprint.identityParts\",\"input\":{"
                "\"parts\":[[\"a\",\"1\"],[\"a\",\"2\"]]}}",
                TB_SESSION_INVALID_MESSAGE, "duplicate key");
  EXPECT_STATUS("{\"type\":\"fingerprint.identityParts\",\"input\":{"
                "\"parts\":[[\"a\"]]}}",
                TB_SESSION_INVALID_MESSAGE, "$.input.parts[0]");
  EXPECT_STATUS(event_message(kSession,
                              "{\"id\":\"e\",\"atMs\":1.0,\"type\":\"t\","
                              "\"stream\":\"evidence\"}"),
                TB_SESSION_INVALID_MESSAGE, "$.input.event.atMs");
  EXPECT_STATUS(event_message(kSession,
                              "{\"id\":\"e\",\"atMs\":1,\"type\":\"t\","
                              "\"stream\":\"debug\"}"),
                TB_SESSION_INVALID_MESSAGE, "unsupported stream");
  EXPECT_STATUS(event_message(kSession,
                              "{\"id\":\"e\",\"atMs\":1,\"type\":\"t\","
                              "\"stream\":\"evidence\",\"result\":"
                              "\"no_visible_change\"}"),
                TB_SESSION_INVALID_MESSAGE, "unsupported result");
  EXPECT_STATUS(event_message(kSession,
                              "{\"id\":\"e\",\"atMs\":1,\"type\":\"t\","
                              "\"stream\":\"evidence\",\"targetAnchor\":{"
                              "\"actions\":[\"tap\",null]}}"),
                TB_SESSION_INVALID_MESSAGE, "actions[1]");
  EXPECT_STATUS(event_message(kSession,
                              "{\"id\":\"e\",\"atMs\":1,\"type\":\"t\","
                              "\"stream\":\"evidence\",\"targetAnchor\":{"
                              "\"fingerprintParts\":{\"schemaVersion\":6}}}"),
                TB_SESSION_INVALID_MESSAGE, "fingerprintParts.schemaVersion");
  EXPECT_STATUS(event_message("{\"startedAtEpochMs\":0,\"traits\":{}}", kEvent),
                TB_SESSION_INVALID_MESSAGE, "lifecycle only");
  EXPECT_STATUS(event_message("{\"startedAtEpochMs\":8640000000000001}",
                              kEvent),
                TB_SESSION_INVALID_MESSAGE, "startedAtEpochMs");
  EXPECT_STATUS(event_message("{\"startedAtEpochMs\":0,\"user\":\"u\"}",
                              kEvent),
                TB_SESSION_INVALID_MESSAGE, "$.input.session.user");
  EXPECT_STATUS(lifecycle_message("{\"startedAtEpochMs\":0}",
                                  "{\"eventType\":\"session_end\","
                                  "\"triggeredAtEpochMs\":1}"),
                TB_SESSION_INVALID_MESSAGE, "$.input.session.sessionId");
  // Opaque data that Dart could not encode.
  EXPECT_STATUS(event_message(kSession,
                              "{\"id\":\"e\",\"atMs\":1,\"type\":\"t\","
                              "\"stream\":\"evidence\",\"data\":{\"x\":1e400}}"),
                TB_SESSION_INVALID_MESSAGE, "$.result.record.payload.x");
  tb_session_engine_destroy(engine);
}

void test_dropped_non_finite_is_ok() {
  // Dart only fails when a non-finite value reaches the encoder; a dropped
  // interaction key is never encoded.
  tb_session_engine* engine = make_engine();
  const Response r = submit(
      engine, event_message(kSession,
                            "{\"id\":\"e\",\"atMs\":1,\"type\":\"interaction\","
                            "\"stream\":\"semantic\",\"data\":{\"x\":1e400}}"));
  CHECK(r.status == TB_SESSION_OK);
  CHECK(contains(r.json, "\"interactionSchema\":2"));
  tb_session_engine_destroy(engine);
}

void test_limits() {
  tb_session_engine* engine = make_engine(2, 64);
  EXPECT_STATUS(std::string(65, ' '), TB_SESSION_MESSAGE_TOO_LARGE, "64");
  EXPECT_STATUS("[[[1]]]", TB_SESSION_MALFORMED_MESSAGE, "depth");
  tb_session_engine_destroy(engine);
}

void test_response_shape_and_ownership() {
  tb_session_engine* engine = make_engine();
  const std::string message =
      "{\"type\":\"fingerprint.labelHash\",\"input\":{\"value\":\"abc\"}}";
  const char* out = nullptr;
  size_t len = 0;
  CHECK(tb_session_engine_submit_v1(engine, message.data(), message.size(),
                                    &out, &len) == TB_SESSION_OK);
  CHECK(out != nullptr && out[len] == '\0' && std::strlen(out) == len);
  CHECK_EQ(std::string(out, len),
           std::string("{\"type\":\"fingerprint.labelHash\",\"result\":{"
                       "\"hash\":\"ba7816bf8f01cfea\"},\"effects\":[]}"));
  // The message buffer is not retained: overwrite it and resubmit.
  std::string scratch = message;
  const std::string first(out, len);
  CHECK(tb_session_engine_submit_v1(engine, scratch.data(), scratch.size(),
                                    &out, &len) == TB_SESSION_OK);
  scratch.assign(scratch.size(), 'x');
  CHECK_EQ(std::string(out, len), first);
  // An error replaces the previous response buffer contents.
  const std::string bad = "{";
  CHECK(tb_session_engine_submit_v1(engine, bad.data(), bad.size(), &out,
                                    &len) == TB_SESSION_MALFORMED_MESSAGE);
  CHECK(contains(std::string(out, len), "\"status\":\"malformed_message\""));
  // Handles are independent.
  tb_session_engine* other = make_engine();
  const Response r = submit(other, message);
  CHECK(r.status == TB_SESSION_OK);
  CHECK(contains(std::string(out, len), "malformed_message"));
  tb_session_engine_destroy(other);
  // destroy frees the response buffer (LeakSanitizer checks this run).
  tb_session_engine_destroy(engine);
}

void test_lone_surrogate_through_abi() {
  tb_session_engine* engine = make_engine();
  const Response r = submit(
      engine, "{\"type\":\"fingerprint.identityParts\",\"input\":{\"parts\":"
              "[[\"k\",\"\\ud800\"]]}}");
  CHECK(r.status == TB_SESSION_OK);
  // Escaped like Dart jsonEncode; hashed over U+FFFD like utf8.encode.
  CHECK(contains(r.json, "\"canonicalString\":\"k=\\ud800\""));
  const std::string expected_hash =
      tugboat::engine::sha256_hex("k=\xEF\xBF\xBD").substr(0, 16);
  CHECK(contains(r.json, "\"fingerprint\":\"" + expected_hash + "\""));
  tb_session_engine_destroy(engine);
}

}  // namespace

int main() {
  test_number_round_trip();
  test_format_double();
  test_parse_grammar();
  test_string_escaping();
  test_object_set_semantics();
  test_sha256();
  test_label_hash();
  test_compare_utf16();
  test_dart_time();
  test_version_queries();
  test_create_errors();
  test_submit_null_arguments();
  test_submit_errors();
  test_dropped_non_finite_is_ok();
  test_limits();
  test_response_shape_and_ownership();
  test_lone_surrogate_through_abi();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", g_failures);
    return 1;
  }
  std::printf("all session engine unit tests passed\n");
  return 0;
}
