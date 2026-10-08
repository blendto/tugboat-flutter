#include "dart_time.h"


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

// Appends `value` (>= 0) in decimal, left-padded with zeros to `width`.
// Plain digit arithmetic: no buffer to size and no locale.
void append_padded(std::string* out, uint64_t value, size_t width) {
  char digits[20];  // UINT64_MAX has 20 decimal digits
  size_t count = 0;
  do {
    digits[count++] = static_cast<char>('0' + value % 10);
    value /= 10;
  } while (value != 0);
  for (size_t i = count; i < width; ++i) {
    out->push_back('0');
  }
  while (count > 0) {
    out->push_back(digits[--count]);
  }
}

void append_year(std::string* out, int64_t year) {
  const uint64_t abs_year = year < 0 ? 0 - static_cast<uint64_t>(year)
                                     : static_cast<uint64_t>(year);
  if (year >= -9999 && year <= 9999) {
    // Dart _fourDigits: sign only when negative.
    if (year < 0) {
      out->push_back('-');
    }
    append_padded(out, abs_year, 4);
  } else {
    // Dart _sixDigits: always signed.
    out->push_back(year < 0 ? '-' : '+');
    append_padded(out, abs_year, 6);
  }
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

  std::string out;
  out.reserve(32);
  append_year(&out, year);
  const auto put = [&out](char separator, int value, size_t width) {
    out.push_back(separator);
    append_padded(&out, static_cast<uint64_t>(value), width);
  };
  put('-', month, 2);
  put('-', day, 2);
  put('T', hour, 2);
  put(':', minute, 2);
  put(':', second, 2);
  put('.', millisecond, 3);
  if (microsecond != 0) {
    append_padded(&out, static_cast<uint64_t>(microsecond), 3);
  }
  out.push_back('Z');
  return out;
}

}  // namespace engine
}  // namespace tugboat
