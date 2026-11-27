// Runs `evidence.externalEvent` and `evidence.networkCall` fixtures
// (conformance/README.md): the fixture input is the message input, sent to
// a fresh engine whose session started at monoUs 0, and `expected.data` is
// the recorded event's `data` (null when nothing is recorded). Object key
// order is compared too, because the data must be byte-identical to Dart's.
#ifndef TUGBOAT_SESSION_ENGINE_TESTS_EVIDENCE_RUNNER_H
#define TUGBOAT_SESSION_ENGINE_TESTS_EVIDENCE_RUNNER_H

#include <string>

#include "conformance_json.h"

namespace conformance {

constexpr char kExternalEventKind[] = "evidence.externalEvent";
constexpr char kNetworkCallKind[] = "evidence.networkCall";

bool is_evidence_kind(const std::string& kind);

// Prints and returns false on failure.
bool run_evidence(const Json& fixture, const std::string& source,
                  const std::string& relative);

}  // namespace conformance

#endif  // TUGBOAT_SESSION_ENGINE_TESTS_EVIDENCE_RUNNER_H
