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

// Trims whitespace; returns nullopt when empty or longer than
// [kMaxRetryAfterHeaderBytes] (field should be dropped, not rejected).
std::optional<std::string> trim_retry_after_field(const std::string& raw);

// Returns delay in milliseconds to wait before retrying, capped at [cap_ms].
// `now_wall_us` is UTC epoch microseconds (required for HTTP-date). Unparseable
// values yield nullopt.
std::optional<int64_t> parse_retry_after_delay_ms(
    const std::string& raw, std::optional<int64_t> now_wall_us, int64_t cap_ms);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_RETRY_AFTER_H
