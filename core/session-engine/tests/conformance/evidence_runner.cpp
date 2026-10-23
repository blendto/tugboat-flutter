#include "evidence_runner.h"

#include <cstdio>
#include <string>
#include <vector>

#include "engine_client.h"

namespace conformance {

namespace {

using Kind = Json::Kind;

constexpr char kConfigure[] =
    R"({"type":"engine.configure","input":{"host":{"app":{"name":"Example App","version":"2.4.0","buildNumber":"240","installationId":"inst-0001","appId":"com.example.app"},"device":{"id":"device-0001","platform":"android","screenSize":{"width":412.0,"height":915.0},"screenDensity":2.625,"screenDpi":420,"screenPixelDensity":2.625},"ip":{"ip":"203.0.113.7"},"locale":{},"configuredUserId":null}}})";

constexpr char kSessionStart[] =
    R"({"type":"session.start","at":{"monoUs":0,"wallUs":1781827200000000},"input":{"viewport":{"width":412.0,"height":915.0},"platform":"android","sessionEpoch":0}})";

// The message's `at.monoUs`: when a network call ends (default its start),
// or when an external event happens (default 0).
std::string at_mono_us(const Json& input, const std::string& kind,
                       const std::string& source) {
  const char* key = kind == kNetworkCallKind ? "endMonoUs" : "atMonoUs";
  const Json* at = input.find(key);
  if (at == nullptr && kind == kNetworkCallKind) {
    at = input.find("startMonoUs");
  }
  return at != nullptr && at->is(Kind::kInt) ? source_of(*at, source) : "0";
}

// Object key order, recursively: Dart's data is a `LinkedHashMap`.
void compare_order(const Json& expected, const Json& actual,
                   const std::string& path, Diff* diff) {
  if (expected.kind != actual.kind) {
    return;  // the type-strict diff reports it
  }
  if (expected.is(Kind::kObject)) {
    std::string e;
    std::string a;
    for (const auto& member : expected.members) {
      e += member.first + ",";
    }
    for (const auto& member : actual.members) {
      a += member.first + ",";
    }
    if (e == a) {
      for (size_t i = 0; i < expected.members.size(); ++i) {
        compare_order(expected.members[i].second, actual.members[i].second,
                      path + "." + expected.members[i].first, diff);
      }
    } else {
      diff->note(path + ": key order " + a + " (expected " + e + ")");
    }
  }
  if (expected.is(Kind::kArray) &&
      expected.items.size() == actual.items.size()) {
    for (size_t i = 0; i < expected.items.size(); ++i) {
      compare_order(expected.items[i], actual.items[i],
                    path + "[" + std::to_string(i) + "]", diff);
    }
  }
}

bool fail_with(const std::string& relative, const std::string& why) {
  std::printf("FAIL %s\n  %s\n", relative.c_str(), why.c_str());
  return false;
}

// The `data` of the one event record in `response`, or null when there is
// none. Returns false when the response is not a recorded single event.
bool recorded_data(const Json& response, const std::string& kind,
                   const Json** data, std::string* why) {
  const Json* records = response.find("records");
  if (records == nullptr || !records->is(Kind::kArray) ||
      records->items.size() > 1) {
    *why = "expected at most one record";
    return false;
  }
  *data = nullptr;
  if (records->items.empty()) {
    return true;
  }
  const Json* event = records->items[0].find("event");
  const char* type =
      kind == kNetworkCallKind ? "network_call" : "external_event";
  if (event == nullptr || event->find("type") == nullptr ||
      event->find("type")->text != type) {
    *why = std::string("expected a ") + type + " event record";
    return false;
  }
  *data = event->find("data");
  return true;
}

}  // namespace

bool is_evidence_kind(const std::string& kind) {
  return kind == kExternalEventKind || kind == kNetworkCallKind;
}

bool run_evidence(const Json& fixture, const std::string& source,
                  const std::string& relative) {
  const std::string& kind = fixture.find("kind")->text;
  const Json& input = *fixture.find("input");
  const Json& expected = *fixture.find("expected");
  const Json* expected_data = expected.find("data");
  if (expected.members.size() != 1 || expected_data == nullptr ||
      !(expected_data->is(Kind::kObject) || expected_data->is(Kind::kNull))) {
    return fail_with(relative, "expected must be {data: object or null}");
  }
  EngineClient engine;
  if (engine.submit(kConfigure).status != TB_SESSION_OK ||
      engine.submit(kSessionStart).status != TB_SESSION_OK) {
    return fail_with(relative, "could not start the session");
  }
  const std::string message =
      "{\"type\":\"" + kind + "\",\"at\":{\"monoUs\":" +
      at_mono_us(input, kind, source) + "},\"input\":" +
      source_of(input, source) + "}";
  const Response response = engine.submit(message);
  Json parsed;
  std::string why;
  if (response.status != TB_SESSION_OK ||
      !parse(response.json, &parsed, &why)) {
    return fail_with(relative, std::string("engine status ") +
                                   tb_session_status_name(response.status) +
                                   ": " + response.json);
  }
  const Json* data = nullptr;
  if (!recorded_data(parsed, kind, &data, &why)) {
    return fail_with(relative, why + ": " + response.json);
  }
  const Json null_json;
  const Json& actual = data != nullptr ? *data : null_json;
  Diff diff(source, response.json);
  diff.compare(*expected_data, actual, "$.expected.data");
  if (diff.empty()) {
    compare_order(*expected_data, actual, "$.expected.data", &diff);
  }
  if (diff.empty()) {
    std::printf("ok   %s\n", relative.c_str());
    return true;
  }
  std::printf("FAIL %s does not match the engine:\n", relative.c_str());
  for (const std::string& line : diff.lines()) {
    std::printf("  %s\n", line.c_str());
  }
  std::printf("  actual data: %s\n",
              data != nullptr ? source_of(*data, response.json).c_str()
                              : "null");
  return false;
}

}  // namespace conformance
