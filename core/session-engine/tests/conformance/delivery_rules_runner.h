// Runs `delivery.rules` fixtures (conformance/README.md): the collector
// delivery rules both the C++ engine and Dart's `CollectorHttpSink` follow,
// written as actions (record an event, capture a frame, answer the request
// in flight) and what delivery sends and reports after each. This runner
// turns the actions into engine messages and the engine's `http.send`
// effects and `engine.health` answer into the fixture's summary vocabulary.
#ifndef TUGBOAT_SESSION_ENGINE_TESTS_DELIVERY_RULES_RUNNER_H
#define TUGBOAT_SESSION_ENGINE_TESTS_DELIVERY_RULES_RUNNER_H

#include <string>

#include "conformance_json.h"

namespace conformance {

constexpr char kDeliveryRulesKind[] = "delivery.rules";

// Prints and returns false on failure.
bool run_delivery_rules(const Json& fixture, const std::string& source,
                        const std::string& relative);

}  // namespace conformance

#endif  // TUGBOAT_SESSION_ENGINE_TESTS_DELIVERY_RULES_RUNNER_H
