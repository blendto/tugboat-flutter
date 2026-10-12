#include "capture_budget.h"

#include <algorithm>
#include <limits>

namespace tugboat {
namespace engine {

namespace {

// Costs come from host-reported timings and fact time differences, so the
// sum saturates instead of overflowing.
int64_t saturating_add(int64_t a, int64_t b) {
  const int64_t max = std::numeric_limits<int64_t>::max();
  return a > max - b ? max : a + b;
}

}  // namespace

void CaptureBudget::record(int64_t now_mono_us, int64_t cost_us,
                           int64_t window_us, int64_t budget_us) {
  // Dart `_prune`: samples older than the window leave it.
  samples_.erase(std::remove_if(samples_.begin(), samples_.end(),
                                [&](const Sample& sample) {
                                  return now_mono_us - sample.at_mono_us >
                                         window_us;
                                }),
                 samples_.end());
  samples_.push_back({now_mono_us, std::max<int64_t>(cost_us, 0)});
  int64_t total = 0;
  for (const Sample& sample : samples_) {
    total = saturating_add(total, sample.cost_us);
  }
  degraded_ = total > budget_us;
}

}  // namespace engine
}  // namespace tugboat
