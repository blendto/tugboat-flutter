#include "teardown.h"

namespace tugboat {
namespace engine {

const std::array<TeardownStage, kTeardownStageCount>& teardown_order(
    TeardownCause cause) {
  return cause == TeardownCause::kSessionReplacement ? kReplacementOrder
                                                     : kDeactivationOrder;
}

}  // namespace engine
}  // namespace tugboat
