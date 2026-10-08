// Dart `DateTime` arithmetic and formatting the collector mapping relies on.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DART_TIME_H
#define TUGBOAT_SESSION_ENGINE_DART_TIME_H

#include <cstdint>
#include <string>

namespace tugboat {
namespace engine {

// Dart's DateTime range: |microseconds since epoch| <= 8.64e18.
constexpr int64_t kMaxEpochMs = 8640000000000000;

// `DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)` is valid.
bool epoch_ms_in_range(int64_t ms);

// `DateTime.fromMillisecondsSinceEpoch(start_ms).add(Duration(milliseconds:
// at_ms))` in epoch microseconds, using Dart VM 64-bit wrapping arithmetic
// for `at_ms * 1000` and the sum. Returns false where Dart throws a
// RangeError (result outside the DateTime range).
bool dart_add_ms(int64_t start_ms, int64_t at_ms, int64_t* out_micros);

// `DateTime.fromMicrosecondsSinceEpoch(us, isUtc: true).toIso8601String()`:
// `YYYY-MM-DDTHH:MM:SS.mmmZ`, three more fractional digits when the
// microsecond part is non-zero, and `±YYYYYY` years outside 0..9999.
// `micros` must be in range.
std::string dart_iso8601_utc(int64_t micros);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DART_TIME_H
