// The rolling screenshot budget (Dart `TugboatScreenshotBudgetTracker`):
// the capture cost charged within the last `budgetWindowMs`, and whether it
// exceeds `budgetMs`. Degraded, eligible captures reuse a compatible frame
// instead of capturing, and physical captures run at `degradedScale`.
// Change C1: the window uses the host monotonic clock of each fact.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_BUDGET_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_BUDGET_H

#include <cstdint>
#include <deque>

namespace tugboat {
namespace engine {

class CaptureBudget {
 public:
  // Charges `cost_us` at `now_mono_us`. Like Dart, the window is pruned and
  // `degraded` recomputed only when a cost is recorded.
  void record(int64_t now_mono_us, int64_t cost_us, int64_t window_us,
              int64_t budget_us);
  bool degraded() const { return degraded_; }

 private:
  struct Sample {
    int64_t at_mono_us;
    int64_t cost_us;
  };

  std::deque<Sample> samples_;
  bool degraded_ = false;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_BUDGET_H
