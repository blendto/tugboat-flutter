// Parses `Retry-After` header values for collector delivery (RFC 9110).
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_RETRY_AFTER_H
#define TUGBOAT_SESSION_ENGINE_RETRY_AFTER_H

#include <cstdint>
#include <optional>
#include <string>

namespace tugboat {
namespace engine {

constexpr size_t kMaxRetryAfterHeaderBytes = 128;

// Returns delay in milliseconds to wait before retrying, capped at [cap_ms].
// Trims ASCII whitespace first; a value that is empty or longer than
// [kMaxRetryAfterHeaderBytes] after the trim is ignored (nullopt), never
// rejected. `now_wall_us` is UTC epoch microseconds (required for
// HTTP-date). Unparseable values yield nullopt.
std::optional<int64_t> parse_retry_after_delay_ms(
    const std::string& raw, std::optional<int64_t> now_wall_us, int64_t cap_ms);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_RETRY_AFTER_H
