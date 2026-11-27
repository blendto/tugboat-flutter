// External-event and network-call evidence: Flutter's parameter policy,
// limits, and normalization, written once for every host
// (docs/evidence-messages.md). Inputs are decoded evidence values
// (evidence_value.h). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_EVIDENCE_H
#define TUGBOAT_SESSION_ENGINE_EVIDENCE_H

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "evidence_value.h"
#include "json.h"

namespace tugboat {
namespace engine {

// Dart `TugboatParameterLimits`.
struct ParameterLimits {
  static constexpr size_t kMaxDepth = 4;
  static constexpr size_t kMaxTopLevelKeys = 64;
  static constexpr size_t kMaxCollectionItems = 256;
  static constexpr size_t kMaxKeyLength = 128;
  static constexpr size_t kMaxStringLength = 1024;
  static constexpr size_t kMaxEncodedBytes = 16 * 1024;
  static constexpr size_t kMaxNameLength = 256;
  static constexpr size_t kMaxSourceLength = 128;
};

// Dart `TugboatNetworkLimits`.
struct NetworkLimits {
  static constexpr size_t kMaxMethodLength = 16;
  static constexpr size_t kMaxRouteLength = 256;
  static constexpr size_t kMaxErrorResponseBodyBytes = 4 * 1024;
  static constexpr size_t kMaxErrorResponseBodyDepth = 6;
  static constexpr size_t kMaxErrorResponseBodyCollectionItems = 128;
};

enum class ParameterMode { kNamesOnly, kAllowList, kTransform, kAllowAll };

// `names_only`, `allow_list`, `transform`, `allow_all`.
std::optional<ParameterMode> parse_parameter_mode(const std::string& name);
const char* parameter_mode_name(ParameterMode mode);

struct ParameterPolicy {
  ParameterMode mode = ParameterMode::kAllowAll;
  std::vector<std::string> allowed_keys;  // sorted, for allow_list
};

// Dart `boundExternalLabel`: trimmed, cut to `max_units` UTF-16 units;
// nullopt when empty after trimming.
std::optional<std::string> bound_external_label(std::string_view value,
                                                size_t max_units);

// The `external_event` data (Dart `recordExternalEvent`), or nullopt when
// the name is empty after trimming (nothing is recorded). `parameters` is
// the decoded parameters map, or nullptr.
std::optional<Value> external_event_data(
    std::string_view name, const std::optional<std::string>& source,
    const ParameterPolicy& policy, const EvidenceValue* parameters);

// Dart `normalizeNetworkMethod`, except that a non-ASCII method is invalid
// (Dart upper-cases it with Unicode simple case mapping).
std::optional<std::string> normalize_network_method(std::string_view method);

// Dart `normalizeNetworkRoute`.
std::optional<std::string> normalize_network_route(std::string_view route);

// `errorResponseBody`: a decoded value (`{"value"}`) or JSON text the
// engine decodes as Dart's `jsonDecode` would (`{"jsonText"}`).
struct ErrorBody {
  std::optional<EvidenceValue> value;
  std::string json_text;
};

// Dart `TugboatNetworkErrorBodySnapshot`.
struct ErrorBodySnapshot {
  Value value;
  std::string format;  // `text` or `json`
  std::string representation = "native";
  bool truncated = false;
};

// Dart `snapshotNetworkErrorResponseBody`; nullopt for no body.
std::optional<ErrorBodySnapshot> snapshot_error_body(const ErrorBody& body);

// Dart `TugboatNetworkOutcome`.
enum class NetworkOutcome { kResponse, kNetworkError, kCancelled };

std::optional<NetworkOutcome> parse_network_outcome(const std::string& name);
const char* network_outcome_name(NetworkOutcome outcome);

// A finished call as the host reports it.
struct NetworkCall {
  std::string method;  // as sent, normalized when recorded
  std::string route;
  std::optional<int64_t> status_code;
  NetworkOutcome outcome = NetworkOutcome::kResponse;
  std::optional<int64_t> attempt_count;
  std::optional<ErrorBody> error_body;
};

// The `network_call` data (Dart `_finishNetworkCall`) for the normalized
// `method` and `route`. The body is read only for status >= 400.
Value network_call_data(const NetworkCall& call, std::string method,
                        std::string route, int64_t duration_ms);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_EVIDENCE_H
