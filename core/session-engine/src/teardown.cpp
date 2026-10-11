#include "teardown.h"

#include <utility>

namespace tugboat {
namespace engine {

const std::array<TeardownStage, kTeardownStageCount>& teardown_order(
    TeardownCause cause) {
  return cause == TeardownCause::kSessionReplacement ? kReplacementOrder
                                                     : kDeactivationOrder;
}

void Teardown::on(TeardownStage stage, Handler handler) {
  handlers_[static_cast<size_t>(stage)].push_back(std::move(handler));
}

void Teardown::run(TeardownCause cause, Output* out) const {
  for (TeardownStage stage : teardown_order(cause)) {
    for (const Handler& handler : handlers_[static_cast<size_t>(stage)]) {
      handler(cause, out);
    }
  }
}

}  // namespace engine
}  // namespace tugboat
