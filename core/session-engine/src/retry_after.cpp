#include "retry_after.h"

#include <cctype>
#include <climits>
#include <cstdlib>
#include <cstring>

namespace tugboat {
namespace engine {

namespace {

std::string trim(const std::string& raw) {
  size_t begin = 0;
  while (begin < raw.size() && std::isspace(static_cast<unsigned char>(raw[begin]))) {
    ++begin;
  }
  size_t end = raw.size();
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(raw[end - 1]))) {
    --end;
  }
  return raw.substr(begin, end - begin);
}

bool parse_delta_seconds(const std::string& value, int64_t* out_seconds) {
  if (value.empty()) {
    return false;
  }
  int64_t seconds = 0;
  for (char ch : value) {
    if (ch < '0' || ch > '9') {
      return false;
    }
    if (seconds > (INT64_MAX - (ch - '0')) / 10) {
      return false;
    }
    seconds = seconds * 10 + (ch - '0');
  }
  *out_seconds = seconds;
  return true;
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

// IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT` (RFC 9110 preferred form).
bool parse_imf_fixdate(const std::string& value, int64_t* out_epoch_ms) {
  if (value.size() < 29 || value[value.size() - 3] != 'G' ||
      value[value.size() - 2] != 'M' || value[value.size() - 1] != 'T') {
    return false;
  }
  if (value[3] != ',' || value[4] != ' ') {
    return false;
  }
  const int day = std::atoi(value.substr(5, 2).c_str());
  const int month = month_index(value.c_str() + 8);
  const int year = std::atoi(value.substr(12, 4).c_str());
  const int hour = std::atoi(value.substr(17, 2).c_str());
  const int minute = std::atoi(value.substr(20, 2).c_str());
  const int second = std::atoi(value.substr(23, 2).c_str());
  if (month == 0 || day < 1 || day > 31 || hour > 23 || minute > 59 ||
      second > 59) {
    return false;
  }
  const int64_t days = days_from_civil(year, month, day);
  *out_epoch_ms = days * 86400000LL + hour * 3600000LL + minute * 60000LL +
                    second * 1000LL;
  return true;
}

int64_t cap_delay(int64_t delay_ms, int64_t cap_ms) {
  if (delay_ms < 0) {
    return 0;
  }
  return delay_ms > cap_ms ? cap_ms : delay_ms;
}

}  // namespace

std::optional<int64_t> parse_retry_after_delay_ms(const std::string& raw,
                                                    int64_t now_wall_us,
                                                    int64_t cap_ms) {
  const std::string value = trim(raw);
  if (value.empty() || value.size() > kMaxRetryAfterHeaderBytes) {
    return std::nullopt;
  }
  int64_t seconds = 0;
  if (parse_delta_seconds(value, &seconds)) {
    if (seconds > INT64_MAX / 1000) {
      return cap_ms;
    }
    return cap_delay(seconds * 1000, cap_ms);
  }
  int64_t epoch_ms = 0;
  if (!parse_imf_fixdate(value, &epoch_ms)) {
    return std::nullopt;
  }
  const int64_t now_ms = now_wall_us / 1000;
  return cap_delay(epoch_ms - now_ms, cap_ms);
}

}  // namespace engine
}  // namespace tugboat
