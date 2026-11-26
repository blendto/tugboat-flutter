#include "clock.h"

#include "dart_time.h"

namespace tugboat {
namespace engine {

namespace {

// Dart's DateTime range in microseconds.
constexpr int64_t kMaxEpochUs = kMaxEpochMs * 1000;

// The largest monotonic time stamp (about 146,000 years). Every deadline is a
// time stamp plus at most a few days, and every budget cost a difference of
// time stamps plus at most a day, so none of them can overflow int64.
constexpr int64_t kMaxMonoUs = int64_t{1} << 62;

}  // namespace

bool decode_mono_us(const ObjectReader& r, const char* key,
                    std::optional<int64_t>* out) {
  if (!r.opt_int(key, out)) {
    return false;
  }
  if (*out && **out < 0) {
    return r.reject(key, "must not be negative");
  }
  if (*out && **out > kMaxMonoUs) {
    return r.reject(key, "must be at most 4611686018427387904");
  }
  return true;
}

bool decode_at(const Value* json, AtRule rule, const std::string& path,
               std::optional<At>* out, Error* error) {
  out->reset();
  if (rule == AtRule::kNone) {
    if (json != nullptr) {
      return invalid(error, path, "unknown key");
    }
    return true;
  }
  if (json == nullptr || json->is_null()) {
    return rule == AtRule::kOptional || invalid(error, path, "required");
  }
  if (!json->is_object()) {
    return invalid(error, path, "expected object");
  }
  const ObjectReader r(*json, path, error);
  std::optional<int64_t> mono;
  At at;
  if (!r.check_keys({"monoUs", "wallUs"}) ||
      !decode_mono_us(r, "monoUs", &mono) ||
      !r.opt_int("wallUs", &at.wall_us)) {
    return false;
  }
  if (!mono) {
    return invalid(error, r.child("monoUs"), "required");
  }
  at.mono_us = *mono;
  if (!at.wall_us && rule == AtRule::kMonoAndWall) {
    return invalid(error, r.child("wallUs"), "required");
  }
  if (at.wall_us &&
      (*at.wall_us > kMaxEpochUs || *at.wall_us < -kMaxEpochUs)) {
    return invalid(error, r.child("wallUs"), "outside the DateTime range");
  }
  *out = at;
  return true;
}

int64_t elapsed_ms(int64_t start_mono_us, int64_t fact_mono_us) {
  // Both are non-negative, so the difference cannot overflow.
  if (fact_mono_us <= start_mono_us) {
    return 0;
  }
  return (fact_mono_us - start_mono_us) / 1000;
}

void Timers::schedule(const std::string& timer_id, int64_t at_mono_us,
                      Output* out) {
  deadlines_[timer_id] = at_mono_us;
  out->effects.push_back(TimerSchedule{timer_id, at_mono_us});
}

void Timers::cancel(const std::string& timer_id, Output* out) {
  if (deadlines_.erase(timer_id) != 0) {
    out->effects.push_back(TimerCancel{timer_id});
  }
}

bool Timers::take_due(const std::string& timer_id, int64_t now_mono_us) {
  const auto it = deadlines_.find(timer_id);
  if (it == deadlines_.end() || now_mono_us < it->second) {
    return false;
  }
  deadlines_.erase(it);
  return true;
}

bool Timers::armed(const std::string& timer_id) const {
  return deadlines_.count(timer_id) != 0;
}

bool timer_key(const std::string& timer_id, const char* prefix,
               std::string* key) {
  const std::string head(prefix);
  if (timer_id.compare(0, head.size(), head) != 0) return false;
  *key = timer_id.substr(head.size());
  return true;
}

}  // namespace engine
}  // namespace tugboat
