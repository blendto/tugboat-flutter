// The host's answer to `http.send` (docs/stateful-engine.md sections 3.1 and
// 7.4): the `transport.result` input and how the engine classifies it.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_TRANSPORT_H
#define TUGBOAT_SESSION_ENGINE_TRANSPORT_H

#include <cstdint>
#include <optional>
#include <string>

#include "json.h"
#include "reader.h"

namespace tugboat {
namespace engine {

// The largest response body a host passes back (the first 64 KiB).
constexpr size_t kMaxResponseBodyBytes = 64 * 1024;

enum class TransportOutcome { kHttp, kError, kTimeout };

// `transport.result {requestId, outcome, status?, body?, retryAfter?}`.
// `status` is required with `outcome: "http"` and not allowed otherwise;
// `body` and `retryAfter` are only allowed with `http`.
struct TransportResult {
  std::string request_id;
  TransportOutcome outcome = TransportOutcome::kError;
  std::optional<int64_t> status;
  std::string body;
  std::optional<std::string> retry_after;
};

bool decode_transport_result(const Value& input, const std::string& path,
                             TransportResult* out, Error* error);

// What a result means (Dart `_classifyResponse`, change C8 kept):
// HTTP 202 is accepted; 408, 429, 5xx, a transport error, and a timeout are
// retried; every other status (200, 201, 204, 400, …) is a permanent drop.
enum class Verdict { kAccepted, kRetry, kDrop };

Verdict classify(const TransportResult& result);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_TRANSPORT_H
