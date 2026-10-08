#include "dart_time.h"

#include <cstdio>

namespace tugboat {
namespace engine {

namespace {

constexpr int64_t kMaxEpochMicros = kMaxEpochMs * 1000;

int64_t floor_div(int64_t a, int64_t b) {
  int64_t q = a / b;
  if ((a % b != 0) && ((a < 0) != (b < 0))) {
    --q;
  }
  return q;
}

// Proleptic Gregorian civil date from days since 1970-01-01, with year 0
// (H. Hinnant, "chrono-compatible low-level date algorithms").
void civil_from_days(int64_t days, int64_t* year, int* month, int* day) {
  days += 719468;
  const int64_t era = floor_div(days, 146097);
  const int64_t doe = days - era * 146097;
  const int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  const int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const int64_t mp = (5 * doy + 2) / 153;
  *day = static_cast<int>(doy - (153 * mp + 2) / 5 + 1);
  *month = static_cast<int>(mp < 10 ? mp + 3 : mp - 9);
  *year = yoe + era * 400 + (*month <= 2 ? 1 : 0);
}

std::string format_year(int64_t year) {
  char buffer[16];
  const int64_t abs_year = year < 0 ? -year : year;
  if (year >= -9999 && year <= 9999) {
    // Dart _fourDigits: sign only when negative.
    std::snprintf(buffer, sizeof(buffer), "%s%04lld", year < 0 ? "-" : "",
                  static_cast<long long>(abs_year));
  } else {
    // Dart _sixDigits: always signed.
    std::snprintf(buffer, sizeof(buffer), "%s%06lld", year < 0 ? "-" : "+",
                  static_cast<long long>(abs_year));
  }
  return buffer;
}

}  // namespace

bool epoch_ms_in_range(int64_t ms) {
  return ms >= -kMaxEpochMs && ms <= kMaxEpochMs;
}

bool dart_add_ms(int64_t start_ms, int64_t at_ms, int64_t* out_micros) {
  if (!epoch_ms_in_range(start_ms)) {
    return false;
  }
  const uint64_t start_us = static_cast<uint64_t>(start_ms) * 1000u;
  const uint64_t delta_us = static_cast<uint64_t>(at_ms) * 1000u;
  const auto sum = static_cast<int64_t>(start_us + delta_us);
  if (sum < -kMaxEpochMicros || sum > kMaxEpochMicros) {
    return false;
  }
  *out_micros = sum;
  return true;
}

std::string dart_iso8601_utc(int64_t micros) {
  const int64_t micros_per_day = 86400LL * 1000000LL;
  const int64_t days = floor_div(micros, micros_per_day);
  int64_t rest = micros - days * micros_per_day;
  int64_t year = 0;
  int month = 0;
  int day = 0;
  civil_from_days(days, &year, &month, &day);
  const auto hour = static_cast<int>(rest / 3600000000LL);
  rest %= 3600000000LL;
  const auto minute = static_cast<int>(rest / 60000000LL);
  rest %= 60000000LL;
  const auto second = static_cast<int>(rest / 1000000LL);
  rest %= 1000000LL;
  const auto millisecond = static_cast<int>(rest / 1000);
  const auto microsecond = static_cast<int>(rest % 1000);

  char buffer[48];
  std::snprintf(buffer, sizeof(buffer), "-%02d-%02dT%02d:%02d:%02d.%03d",
                month, day, hour, minute, second, millisecond);
  std::string out = format_year(year);
  out.append(buffer);
  if (microsecond != 0) {
    std::snprintf(buffer, sizeof(buffer), "%03d", microsecond);
    out.append(buffer);
  }
  out.push_back('Z');
  return out;
}

}  // namespace engine
}  // namespace tugboat
