#include "capture_types.h"

#include "name_table.h"

namespace tugboat {
namespace engine {

namespace {

// Dart `ScreenshotCaptureFailure.name`.
constexpr NamedValue<CaptureFailure> kFailures[] = {
    {"boundaryUnavailable", CaptureFailure::kBoundaryUnavailable},
    {"boundaryDetached", CaptureFailure::kBoundaryDetached},
    {"boundaryReplaced", CaptureFailure::kBoundaryReplaced},
    {"layoutUnavailable", CaptureFailure::kLayoutUnavailable},
    {"paintTimedOut", CaptureFailure::kPaintTimedOut},
    {"paintNotAdvanced", CaptureFailure::kPaintNotAdvanced},
    {"readbackFailed", CaptureFailure::kReadbackFailed},
    {"maskFailed", CaptureFailure::kMaskFailed},
    {"encodingFailed", CaptureFailure::kEncodingFailed},
    {"secureWindow", CaptureFailure::kSecureWindow},
};

constexpr NamedValue<MaskMode> kMaskModes[] = {
    {"precise", MaskMode::kPrecise},
    {"wholeHost", MaskMode::kWholeHost},
    {"wholeFrame", MaskMode::kWholeFrame},
};

constexpr NamedValue<MaskReason> kMaskReasons[] = {
    {"composeDefault", MaskReason::kComposeDefault},
    {"composeVersionUnverified", MaskReason::kComposeVersionUnverified},
    {"composeOwnerUnavailable", MaskReason::kComposeOwnerUnavailable},
    {"interop", MaskReason::kInterop},
    {"regionUnreadable", MaskReason::kRegionUnreadable},
    {"treeUnreadable", MaskReason::kTreeUnreadable},
    {"animating", MaskReason::kAnimating},
    {"unverifiedLayerAllowlist", MaskReason::kUnverifiedLayerAllowlist},
    {"walkExhausted", MaskReason::kWalkExhausted},
    {"noWindowSize", MaskReason::kNoWindowSize},
    {"noDecor", MaskReason::kNoDecor},
    {"representable", MaskReason::kRepresentable},
    {"webView", MaskReason::kWebView},
    {"renderer", MaskReason::kRenderer},
    {"surfaceLayer", MaskReason::kSurfaceLayer},
    {"unclassifiedLayer", MaskReason::kUnclassifiedLayer},
    {"secureText", MaskReason::kSecureText},
};

// Dart `_captureOutcomeWireNames`.
constexpr NamedValue<CaptureOutcome> kOutcomes[] = {
    {"fresh_accepted", CaptureOutcome::kFreshAccepted},
    {"exact_content_reused", CaptureOutcome::kExactContentReused},
    {"perceptual_hash_coalesced", CaptureOutcome::kPerceptualHashCoalesced},
    {"paint_generation_unchanged", CaptureOutcome::kPaintGenerationUnchanged},
    {"screenshot_budget_skip", CaptureOutcome::kScreenshotBudgetSkip},
    {"capture_pressure_drop", CaptureOutcome::kCapturePressureDrop},
    {"no_frame_available", CaptureOutcome::kNoFrameAvailable},
    {"no_compatible_frame", CaptureOutcome::kNoCompatibleFrame},
    {"paint_readiness_timeout", CaptureOutcome::kPaintReadinessTimeout},
    {"boundary_unavailable", CaptureOutcome::kBoundaryUnavailable},
    {"capture_processing_failed", CaptureOutcome::kCaptureProcessingFailed},
    {"cancelled", CaptureOutcome::kCancelled},
    {"superseded_route_epoch", CaptureOutcome::kSupersededRoute},
};

constexpr NamedValue<CancelReason> kCancelReasons[] = {
    {"dispose", CancelReason::kDispose},
    {"session_end", CancelReason::kSessionEnd},
    {"session_replacement", CancelReason::kSessionReplacement},
    {"lifecycle_deactivate", CancelReason::kLifecycleDeactivate},
    {"superseded_route", CancelReason::kSupersededRoute},
    {"route_timeout", CancelReason::kRouteTimeout},
    {"route_transition", CancelReason::kRouteTransition},
    {"capture_pressure", CancelReason::kCapturePressure},
};

}  // namespace

const char* capture_failure_name(CaptureFailure failure) {
  return name_of(kFailures, failure);
}

std::optional<CaptureFailure> parse_capture_failure(const std::string& name) {
  return parse_name(kFailures, name);
}

const char* mask_mode_name(MaskMode mode) { return name_of(kMaskModes, mode); }

std::optional<MaskMode> parse_mask_mode(const std::string& name) {
  return parse_name(kMaskModes, name);
}

const char* mask_reason_name(MaskReason reason) {
  return name_of(kMaskReasons, reason);
}

std::optional<MaskReason> parse_mask_reason(const std::string& name) {
  return parse_name(kMaskReasons, name);
}

const char* capture_outcome_name(CaptureOutcome outcome) {
  return name_of(kOutcomes, outcome);
}

const char* cancel_reason_name(CancelReason reason) {
  return name_of(kCancelReasons, reason);
}

}  // namespace engine
}  // namespace tugboat
