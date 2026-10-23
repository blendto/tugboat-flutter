// Runs `engine.scenario` fixtures step by step through the public C ABI
// (conformance/README.md "engine.scenario").
#ifndef TUGBOAT_SESSION_ENGINE_TESTS_SCENARIO_RUNNER_H
#define TUGBOAT_SESSION_ENGINE_TESTS_SCENARIO_RUNNER_H

#include <set>
#include <string>

#include "conformance_json.h"

namespace conformance {

// The file under conformance/ that lists the section 11 change ids. It is
// not a fixture.
constexpr char kChangeIdsFile[] = "change_ids.json";

// Reads `changeIds` from the change-id list. Returns an empty string on
// success.
std::string read_change_ids(const std::string& source,
                            std::set<std::string>* out);

// Checks the scenario markers, which are valid only on `engine.scenario`:
// - `engineOnly`: a non-empty array of distinct ids from `change_ids`. It
//   implies `runners: ["cpp"]`.
// - `runners`: a non-empty array of distinct `cpp` / `dart` (default both).
// Returns an empty string when valid.
std::string check_markers(const Json& fixture, const std::string& kind,
                          const std::set<std::string>& change_ids);

// Whether the C++ runner runs the fixture (`runners` absent or with `cpp`).
bool runs_on_cpp(const Json& fixture);

// Runs one scenario fixture on a fresh engine. Prints and returns false on
// failure, naming the first failing step and every differing JSON path.
bool run_scenario(const Json& fixture, const std::string& source,
                  const std::string& relative);

}  // namespace conformance

#endif  // TUGBOAT_SESSION_ENGINE_TESTS_SCENARIO_RUNNER_H
