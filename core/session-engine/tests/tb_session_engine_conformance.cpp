// Conformance runner: evaluates every fixture under <repo>/conformance/
// through the public C ABI only and compares the engine's output with the
// fixture's `expected` value using type-strict deep JSON equality (see
// conformance/README.md "Comparison").
//
// Stateless kinds submit `{"type": kind, "contract", "input"}` once and
// compare `result`. `engine.scenario` fixtures run step by step on a fresh
// engine (conformance/scenario_runner.cpp), and evidence fixtures run one
// message in a fresh session (conformance/evidence_runner.cpp).
//
// Usage: tb_session_engine_conformance [fixture-dir] [path-substring]
#include "tugboat/tb_session_engine.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "conformance/conformance_json.h"
#include "conformance/engine_client.h"
#include "conformance/evidence_runner.h"
#include "conformance/scenario_runner.h"
#include "conformance_files.h"

#ifndef TB_CONFORMANCE_DIR
#error "TB_CONFORMANCE_DIR must point at <repo>/conformance"
#endif

namespace fs = std::filesystem;

namespace {

using conformance::Diff;
using conformance::EngineClient;
using conformance::Json;
using conformance::Response;

constexpr int64_t kFixtureFormat = 1;
constexpr char kScenarioKind[] = "engine.scenario";

const std::map<std::string, std::string> kKindDirectories = {
    {"fingerprint.identityParts", "fingerprint/identity_parts"},
    {"fingerprint.labelHash", "fingerprint/label_hash"},
    {"collector.event", "collector/event"},
    {"collector.sessionLifecycle", "collector/session_lifecycle"},
    {kScenarioKind, "engine/scenario"},
    {conformance::kExternalEventKind, "evidence/external_event"},
    {conformance::kNetworkCallKind, "evidence/network_call"},
};

const std::set<std::string> kEnvelopeKeys = {
    "fixtureFormat", "kind",     "name",       "description", "contract",
    "input",         "expected", "engineOnly", "runners",    "dartParity"};

std::string read_file(const fs::path& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream text;
  text << in.rdbuf();
  return text.str();
}

std::string check_contract(const Json& fixture) {
  const Json* contract = fixture.find("contract");
  if (contract == nullptr || !contract->is(Json::Kind::kObject) ||
      contract->members.size() != 2 ||
      !conformance::int_equals(contract->find("sessionSchemaVersion"),
                               tb_session_engine_session_schema_version()) ||
      !conformance::int_equals(
          contract->find("fingerprintSchemaVersion"),
          tb_session_engine_fingerprint_schema_version())) {
    return "fixture is pinned to other contract versions than the engine "
           "(sessionSchemaVersion " +
           std::to_string(tb_session_engine_session_schema_version()) +
           ", fingerprintSchemaVersion " +
           std::to_string(tb_session_engine_fingerprint_schema_version()) +
           "); review and re-pin";
  }
  return std::string();
}

// Checks the envelope; returns an empty string when valid.
std::string check_envelope(const Json& fixture, const std::string& relative,
                           const std::set<std::string>& change_ids) {
  if (!fixture.is(Json::Kind::kObject)) {
    return "fixture is not an object";
  }
  for (const auto& member : fixture.members) {
    if (kEnvelopeKeys.count(member.first) == 0) {
      return "unknown envelope key " + member.first;
    }
  }
  if (!conformance::int_equals(fixture.find("fixtureFormat"),
                               kFixtureFormat)) {
    return "unsupported fixtureFormat (runner reads 1)";
  }
  const Json* kind = fixture.find("kind");
  const Json* name = fixture.find("name");
  const Json* description = fixture.find("description");
  const Json* input = fixture.find("input");
  const Json* expected = fixture.find("expected");
  if (kind == nullptr || !kind->is(Json::Kind::kString) ||
      kKindDirectories.count(kind->text) == 0) {
    return "unknown kind";
  }
  if (name == nullptr || !name->is(Json::Kind::kString) ||
      fs::path(relative).filename().string() != name->text + ".json") {
    return "name must equal the file name stem";
  }
  if (relative.rfind(kKindDirectories.at(kind->text) + "/", 0) != 0) {
    return "kind " + kind->text + " lives in " +
           kKindDirectories.at(kind->text);
  }
  if (description == nullptr || !description->is(Json::Kind::kString)) {
    return "description must be a string";
  }
  if (input == nullptr || !input->is(Json::Kind::kObject) ||
      expected == nullptr || !expected->is(Json::Kind::kObject)) {
    return "input and expected must be objects";
  }
  const std::string markers =
      conformance::check_markers(fixture, kind->text, change_ids);
  if (!markers.empty()) {
    return markers;
  }
  return check_contract(fixture);
}

// Runs one stateless fixture; prints and returns false on failure.
bool run_stateless(EngineClient& engine, const Json& fixture,
                   const std::string& source, const std::string& relative) {
  const Json& kind = *fixture.find("kind");
  // Fixture kind == message type; input is passed through verbatim.
  const std::string message =
      "{\"type\":\"" + kind.text + "\",\"contract\":" +
      conformance::source_of(*fixture.find("contract"), source) +
      ",\"input\":" + conformance::source_of(*fixture.find("input"), source) +
      "}";
  const Response response = engine.submit(message);
  if (response.status != TB_SESSION_OK) {
    std::printf("FAIL %s\n  engine status %s: %s\n", relative.c_str(),
                tb_session_status_name(response.status), response.json.c_str());
    return false;
  }
  Json parsed;
  std::string error;
  if (!conformance::parse(response.json, &parsed, &error) ||
      parsed.find("result") == nullptr) {
    std::printf("FAIL %s\n  unreadable response (%s): %s\n", relative.c_str(),
                error.c_str(), response.json.c_str());
    return false;
  }
  const Json* effects = parsed.find("effects");
  if (effects == nullptr || !effects->is(Json::Kind::kArray) ||
      !effects->items.empty()) {
    std::printf("FAIL %s\n  expected an empty effects array: %s\n",
                relative.c_str(), response.json.c_str());
    return false;
  }
  Diff diff(source, response.json);
  diff.compare(*fixture.find("expected"), *parsed.find("result"),
               "$.expected");
  if (diff.empty()) {
    std::printf("ok   %s\n", relative.c_str());
    return true;
  }
  std::printf("FAIL %s does not match the engine:\n", relative.c_str());
  for (const std::string& line : diff.lines()) {
    std::printf("  %s\n", line.c_str());
  }
  std::printf("  actual result: %s\n",
              conformance::source_of(*parsed.find("result"), response.json)
                  .c_str());
  return false;
}

// Runs one fixture file; prints and returns false on failure.
bool run_fixture(EngineClient& engine, const fs::path& path,
                 const std::string& relative,
                 const std::set<std::string>& change_ids,
                 std::set<std::string>* kinds) {
  const std::string source = read_file(path);
  Json fixture;
  std::string error;
  if (!conformance::parse(source, &fixture, &error)) {
    std::printf("FAIL %s\n  unreadable fixture: %s\n", relative.c_str(),
                error.c_str());
    return false;
  }
  error = check_envelope(fixture, relative, change_ids);
  if (!error.empty()) {
    std::printf("FAIL %s\n  %s\n", relative.c_str(), error.c_str());
    return false;
  }
  const std::string& kind = fixture.find("kind")->text;
  kinds->insert(kind);
  if (!conformance::runs_on_cpp(fixture)) {
    std::printf("skip %s (runners)\n", relative.c_str());
    return true;
  }
  if (kind == kScenarioKind) {
    return conformance::run_scenario(fixture, source, relative);
  }
  if (conformance::is_evidence_kind(kind)) {
    return conformance::run_evidence(fixture, source, relative);
  }
  return run_stateless(engine, fixture, source, relative);
}

}  // namespace

int main(int argc, char** argv) {
  const fs::path root =
      argc > 1 ? fs::path(argv[1]) : fs::path(TB_CONFORMANCE_DIR);
  const std::string filter = argc > 2 ? argv[2] : "";
  if (!fs::exists(root / "README.md")) {
    std::fprintf(stderr, "conformance directory not found: %s\n",
                 root.string().c_str());
    return 2;
  }
  std::set<std::string> change_ids;
  const std::string ids_error = conformance::read_change_ids(
      read_file(root / conformance::kChangeIdsFile), &change_ids);
  if (!ids_error.empty()) {
    std::fprintf(stderr, "%s: %s\n", conformance::kChangeIdsFile,
                 ids_error.c_str());
    return 2;
  }
  std::vector<std::pair<std::string, fs::path>> files;
  for (const auto& entry : fs::recursive_directory_iterator(root)) {
    if (entry.is_regular_file() && entry.path().extension() == ".json") {
      std::string relative = fs::relative(entry.path(), root).generic_string();
      if (relative != conformance::kChangeIdsFile &&
          relative != conformance::kRetryAfterVectorsFile &&
          relative.find(filter) != std::string::npos) {
        files.emplace_back(std::move(relative), entry.path());
      }
    }
  }
  std::sort(files.begin(), files.end());

  // Stateless fixtures share one handle; each scenario gets its own.
  EngineClient engine;
  std::set<std::string> kinds;
  int failures = 0;
  for (const auto& file : files) {
    if (!run_fixture(engine, file.second, file.first, change_ids, &kinds)) {
      ++failures;
    }
  }
  if (filter.empty() && kinds.size() != kKindDirectories.size()) {
    std::printf("FAIL conformance/ must hold fixtures for every kind (%zu of "
                "%zu present)\n",
                kinds.size(), kKindDirectories.size());
    ++failures;
  }
  if (files.empty()) {
    std::printf("FAIL no fixtures found under %s\n", root.string().c_str());
    ++failures;
  }
  std::printf("%zu fixtures, %d failed\n", files.size(), failures);
  return failures == 0 ? 0 : 1;
}
