#include "retry_after.h"

#include <cctype>
#include <climits>
#include <cstring>

namespace tugboat {
namespace engine {

namespace {

std::string trim(const std::string& raw) {
  size_t begin = 0;
  while (begin < raw.size() &&
         std::isspace(static_cast<unsigned char>(raw[begin]))) {
    ++begin;
  }
  size_t end = raw.size();
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(raw[end - 1]))) {
    --end;
  }
  return raw.substr(begin, end - begin);
}

bool all_digits(const std::string& value) {
  if (value.empty()) {
    return false;
  }
  for (char ch : value) {
    if (ch < '0' || ch > '9') {
      return false;
    }
  }
  return true;
}

int64_t cap_delay(int64_t delay_ms, int64_t cap_ms) {
  if (delay_ms < 0) {
    return 0;
  }
  return delay_ms > cap_ms ? cap_ms : delay_ms;
}

int64_t parse_delta_seconds_ms(const std::string& value, int64_t cap_ms) {
  int64_t seconds = 0;
  for (char ch : value) {
    if (seconds > (INT64_MAX - (ch - '0')) / 10) {
      return cap_ms;
    }
    seconds = seconds * 10 + (ch - '0');
    if (seconds > cap_ms / 1000) {
      return cap_ms;
    }
  }
  if (seconds > INT64_MAX / 1000) {
    return cap_ms;
  }
  return cap_delay(seconds * 1000, cap_ms);
}

int month_index(const char* mon) {
  static const char* months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
  for (int i = 0; i < 12; ++i) {
    if (std::strncmp(mon, months[i], 3) == 0) {
      return i + 1;
    }
  }
  return 0;
}

bool weekday_valid(const char* day) {
  static const char* days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
  for (const char* valid : days) {
    if (std::strncmp(day, valid, 3) == 0) {
      return true;
    }
  }
  return false;
}

bool is_digit(char ch) { return ch >= '0' && ch <= '9'; }

int64_t days_from_civil(int year, int month, int day) {
  year -= month <= 2;
  const int era = (year >= 0 ? year : year - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(year - era * 400);
  const unsigned doy =
      (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return static_cast<int64_t>(era) * 146097 +
         static_cast<int64_t>(doe) - 719468;
}

bool civil_valid(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1) {
    return false;
  }
  static const int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  int max_day = days[month - 1];
  if (month == 2) {
    const bool leap =
        (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
    max_day = leap ? 29 : 28;
  }
  return day <= max_day;
}

// IMF-fixdate: exactly `Sun, 06 Nov 1994 08:49:37 GMT` (29 bytes).
bool parse_imf_fixdate(const std::string& value, int64_t* out_epoch_ms) {
  if (value.size() != 29) {
    return false;
  }
  if (!weekday_valid(value.c_str()) || value[3] != ',' || value[4] != ' ' ||
      value[7] != ' ' || value[11] != ' ' || value[16] != ' ' ||
      value[19] != ':' || value[22] != ':' || value[25] != ' ' ||
      value[26] != 'G' || value[27] != 'M' || value[28] != 'T') {
    return false;
  }
  if (!is_digit(value[5]) || !is_digit(value[6]) || !is_digit(value[12]) ||
      !is_digit(value[13]) || !is_digit(value[14]) || !is_digit(value[15]) ||
      !is_digit(value[17]) || !is_digit(value[18]) || !is_digit(value[20]) ||
      !is_digit(value[21]) || !is_digit(value[23]) || !is_digit(value[24])) {
    return false;
  }
  const int day = (value[5] - '0') * 10 + (value[6] - '0');
  const int month = month_index(value.c_str() + 8);
  const int year = (value[12] - '0') * 1000 + (value[13] - '0') * 100 +
                   (value[14] - '0') * 10 + (value[15] - '0');
  const int hour = (value[17] - '0') * 10 + (value[18] - '0');
  const int minute = (value[20] - '0') * 10 + (value[21] - '0');
  int second = (value[23] - '0') * 10 + (value[24] - '0');
  if (month == 0 || !civil_valid(year, month, day) || hour > 23 ||
      minute > 59 || second > 60) {
    return false;
  }
  if (second == 60) {
    second = 59;
  }
  const int64_t days = days_from_civil(year, month, day);
  *out_epoch_ms = days * 86400000LL + hour * 3600000LL + minute * 60000LL +
                    second * 1000LL;
  return true;
}

}  // namespace

std::optional<int64_t> parse_retry_after_delay_ms(
    const std::string& raw, std::optional<int64_t> now_wall_us,
    int64_t cap_ms) {
  const std::string value = trim(raw);
  if (value.empty() || value.size() > kMaxRetryAfterHeaderBytes) {
    return std::nullopt;
  }
  if (all_digits(value)) {
    return parse_delta_seconds_ms(value, cap_ms);
  }
  int64_t epoch_ms = 0;
  if (!parse_imf_fixdate(value, &epoch_ms)) {
    return std::nullopt;
  }
  if (!now_wall_us) {
    return std::nullopt;
  }
  const int64_t now_ms = *now_wall_us / 1000;
  return cap_delay(epoch_ms - now_ms, cap_ms);
}

}  // namespace engine
}  // namespace tugboat
