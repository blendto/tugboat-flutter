// Runs `engine.scenario` fixtures step by step through the public C ABI
// (conformance/README.md "engine.scenario").
#ifndef TUGBOAT_SESSION_ENGINE_TESTS_SCENARIO_RUNNER_H
#define TUGBOAT_SESSION_ENGINE_TESTS_SCENARIO_RUNNER_H

#include <string>

#include "conformance_json.h"

namespace conformance {

// Checks the optional `engineOnly` marker: a non-empty array of distinct
// change ids from docs/stateful-engine.md section 11, and only on
// `engine.scenario`. Returns an empty string when valid.
std::string check_engine_only(const Json& fixture, const std::string& kind);

// Runs one scenario fixture on a fresh engine. Prints and returns false on
// failure, naming the first failing step and every differing JSON path.
bool run_scenario(const Json& fixture, const std::string& source,
                  const std::string& relative);

}  // namespace conformance

#endif  // TUGBOAT_SESSION_ENGINE_TESTS_SCENARIO_RUNNER_H
