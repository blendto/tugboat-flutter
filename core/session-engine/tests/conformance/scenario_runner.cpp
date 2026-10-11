#include "scenario_runner.h"

#include <cstdio>
#include <set>
#include <string>
#include <vector>

#include "engine_client.h"

namespace conformance {

namespace {

using Kind = Json::Kind;

// docs/stateful-engine.md section 11.
const std::set<std::string> kChangeIds = {"C1", "C2", "C3", "C4",
                                          "C5", "C6", "C7", "C8",
                                          "C9", "C10", "C11", "C12"};

bool has_only(const Json& object, const std::set<std::string>& keys) {
  for (const auto& member : object.members) {
    if (keys.count(member.first) == 0) {
      return false;
    }
  }
  return true;
}

bool is_kind(const Json* value, Kind kind) {
  return value != nullptr && value->kind == kind;
}

std::string check_expect(const Json& expect, const std::string& where) {
  if (!expect.is(Kind::kObject)) {
    return where + " must be an object";
  }
  if (const Json* error = expect.find("error")) {
    if (expect.members.size() != 1 || !error->is(Kind::kObject) ||
        !has_only(*error, {"status", "path"}) ||
        !is_kind(error->find("status"), Kind::kString) ||
        (error->find("path") != nullptr &&
         !is_kind(error->find("path"), Kind::kString))) {
      return where + ".error must be {status, path?} strings alone";
    }
    return std::string();
  }
  if (!has_only(expect, {"records", "effects"}) ||
      !is_kind(expect.find("records"), Kind::kArray) ||
      !is_kind(expect.find("effects"), Kind::kArray)) {
    return where + " must be {records, effects} arrays or {error}";
  }
  return std::string();
}

// Validates the scenario `input` and `expected` shapes.
std::string check_shape(const Json& input, const Json& expected) {
  if (!has_only(input, {"configure", "steps"}) ||
      !is_kind(input.find("configure"), Kind::kObject)) {
    return "input must be {configure: object, steps: array}";
  }
  const Json* steps = input.find("steps");
  if (!is_kind(steps, Kind::kArray) || steps->items.empty()) {
    return "input.steps must be a non-empty array";
  }
  for (size_t i = 0; i < steps->items.size(); ++i) {
    const Json& step = steps->items[i];
    const std::string where = "input.steps[" + std::to_string(i) + "]";
    if (!step.is(Kind::kObject) ||
        !has_only(step, {"send", "expect", "note"}) ||
        !is_kind(step.find("send"), Kind::kObject) ||
        !is_kind(step.find("expect"), Kind::kObject) ||
        (step.find("note") != nullptr &&
         !is_kind(step.find("note"), Kind::kString))) {
      return where + " must be {send: object, expect: object, note?}";
    }
    const std::string error =
        check_expect(*step.find("expect"), where + ".expect");
    if (!error.empty()) {
      return error;
    }
  }
  const Json* snapshot = expected.find("finalSnapshot");
  if (!has_only(expected, {"finalSnapshot"}) || snapshot == nullptr ||
      !(snapshot->is(Kind::kObject) || snapshot->is(Kind::kNull))) {
    return "expected must be {finalSnapshot: object | null}";
  }
  return std::string();
}

std::string message_type(const Json& send) {
  const Json* type = send.find("type");
  return is_kind(type, Kind::kString) ? type->text : "?";
}

// Compares an expected error with an error response.
void compare_error(const Json& expected, const Json& actual,
                   const std::string& path, Diff* diff) {
  const Json* error = actual.find("error");
  if (error == nullptr) {
    diff->note(path + ": the response has no error object");
    return;
  }
  for (const char* key : {"status", "path"}) {
    const Json* e = expected.find(key);
    const Json* a = error->find(key);
    if (e == nullptr && a != nullptr) {
      diff->note(path + "." + key + ": unexpected in actual (" + a->text +
                 ")");
    } else if (e != nullptr && a == nullptr) {
      diff->note(path + "." + key + ": missing in actual");
    } else if (e != nullptr) {
      diff->compare(*e, *a, path + "." + key);
    }
  }
}

void compare_step(const Json& expect, const Response& response,
                  const Json& parsed, const std::string& path, Diff* diff) {
  const Json* expected_error = expect.find("error");
  if (expected_error != nullptr) {
    if (response.status == TB_SESSION_OK) {
      diff->note(path + ".error: the engine accepted the message");
      return;
    }
    compare_error(*expected_error, parsed, path + ".error", diff);
    return;
  }
  if (response.status != TB_SESSION_OK) {
    diff->note(path + ": the engine rejected the message (" +
               tb_session_status_name(response.status) + ")");
    return;
  }
  for (const char* key : {"records", "effects"}) {
    const Json* actual = parsed.find(key);
    if (actual == nullptr) {
      diff->note(path + "." + key + ": missing in the response");
    } else {
      diff->compare(*expect.find(key), *actual, path + "." + key);
    }
  }
}

void print_failure(const std::string& relative, const std::string& what,
                   const Diff& diff, const std::string& response) {
  std::printf("FAIL %s %s does not match the engine:\n", relative.c_str(),
              what.c_str());
  for (const std::string& line : diff.lines()) {
    std::printf("  %s\n", line.c_str());
  }
  std::printf("  actual response: %s\n", response.c_str());
}

// Submits `message`; returns false (after printing) when the response is
// not readable JSON.
bool submit(EngineClient* engine, const std::string& message,
            const std::string& relative, Response* response, Json* parsed) {
  *response = engine->submit(message);
  std::string error;
  if (!parse(response->json, parsed, &error)) {
    std::printf("FAIL %s\n  unreadable response (%s): %s\n", relative.c_str(),
                error.c_str(), response->json.c_str());
    return false;
  }
  return true;
}

bool run_configure(EngineClient* engine, const Json& configure,
                   const std::string& source, const std::string& relative) {
  const std::string message = "{\"type\":\"engine.configure\",\"input\":" +
                              source_of(configure, source) + "}";
  Response response;
  Json parsed;
  if (!submit(engine, message, relative, &response, &parsed)) {
    return false;
  }
  const Json* records = parsed.find("records");
  const Json* effects = parsed.find("effects");
  if (response.status != TB_SESSION_OK || !is_kind(records, Kind::kArray) ||
      !records->items.empty() || !is_kind(effects, Kind::kArray) ||
      !effects->items.empty()) {
    std::printf("FAIL %s\n  input.configure was not accepted: %s\n",
                relative.c_str(), response.json.c_str());
    return false;
  }
  return true;
}

bool run_steps(EngineClient* engine, const Json& steps,
               const std::string& source, const std::string& relative) {
  for (size_t i = 0; i < steps.items.size(); ++i) {
    const Json& step = steps.items[i];
    const Json& send = *step.find("send");
    Response response;
    Json parsed;
    if (!submit(engine, source_of(send, source), relative, &response,
                &parsed)) {
      return false;
    }
    Diff diff(source, response.json);
    const std::string path = "$.input.steps[" + std::to_string(i) + "].expect";
    compare_step(*step.find("expect"), response, parsed, path, &diff);
    if (!diff.empty()) {
      print_failure(relative,
                    "step " + std::to_string(i) + " (" + message_type(send) +
                        ")",
                    diff, response.json);
      return false;
    }
  }
  return true;
}

bool run_final_snapshot(EngineClient* engine, const Json& expected,
                        const std::string& source,
                        const std::string& relative) {
  Response response;
  Json parsed;
  if (!submit(engine, "{\"type\":\"session.snapshot\",\"input\":{}}",
              relative, &response, &parsed)) {
    return false;
  }
  const Json* result = parsed.find("result");
  const Json* snapshot = result == nullptr ? nullptr : result->find("snapshot");
  if (response.status != TB_SESSION_OK || snapshot == nullptr) {
    std::printf("FAIL %s\n  session.snapshot failed: %s\n", relative.c_str(),
                response.json.c_str());
    return false;
  }
  Diff diff(source, response.json);
  diff.compare(*expected.find("finalSnapshot"), *snapshot,
               "$.expected.finalSnapshot");
  if (!diff.empty()) {
    print_failure(relative, "final snapshot", diff, response.json);
    return false;
  }
  return true;
}

}  // namespace

std::string check_engine_only(const Json& fixture, const std::string& kind) {
  const Json* marker = fixture.find("engineOnly");
  if (marker == nullptr) {
    return std::string();
  }
  if (kind != "engine.scenario") {
    return "engineOnly is only valid on engine.scenario";
  }
  if (!marker->is(Kind::kArray) || marker->items.empty()) {
    return "engineOnly must be a non-empty array of change ids";
  }
  std::set<std::string> seen;
  for (const Json& id : marker->items) {
    if (!id.is(Kind::kString) || kChangeIds.count(id.text) == 0) {
      return "engineOnly ids must be docs/stateful-engine.md section 11 ids "
             "(C1..C12)";
    }
    if (!seen.insert(id.text).second) {
      return "engineOnly lists " + id.text + " twice";
    }
  }
  return std::string();
}

bool run_scenario(const Json& fixture, const std::string& source,
                  const std::string& relative) {
  const Json& input = *fixture.find("input");
  const Json& expected = *fixture.find("expected");
  const std::string shape = check_shape(input, expected);
  if (!shape.empty()) {
    std::printf("FAIL %s\n  %s\n", relative.c_str(), shape.c_str());
    return false;
  }
  EngineClient engine;
  if (!run_configure(&engine, *input.find("configure"), source, relative) ||
      !run_steps(&engine, *input.find("steps"), source, relative) ||
      !run_final_snapshot(&engine, expected, source, relative)) {
    return false;
  }
  std::printf("ok   %s\n", relative.c_str());
  return true;
}

}  // namespace conformance
