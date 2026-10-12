#include "teardown.h"

namespace tugboat {
namespace engine {

const std::array<TeardownStage, kTeardownStageCount>& teardown_order(
    TeardownCause cause) {
  return cause == TeardownCause::kSessionReplacement ? kReplacementOrder
                                                     : kDeactivationOrder;
}

CancelReason teardown_cancel_reason(TeardownCause cause) {
  switch (cause) {
    case TeardownCause::kLifecycle: return CancelReason::kLifecycleDeactivate;
    case TeardownCause::kSessionEnd: return CancelReason::kSessionEnd;
    case TeardownCause::kDispose: return CancelReason::kDispose;
    case TeardownCause::kSessionReplacement:
      return CancelReason::kSessionReplacement;
  }
  return CancelReason::kSessionEnd;
}

}  // namespace engine
}  // namespace tugboat
