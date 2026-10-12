// The capture vocabulary (docs/stateful-engine.md section 8.2): what the
// host answers to a `capture.request`, who waits for a capture, and what a
// capture resolved to. Shared by the capture scheduler, navigation, and the
// interaction module. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_CAPTURE_TYPES_H
#define TUGBOAT_SESSION_ENGINE_CAPTURE_TYPES_H

#include <cstdint>
#include <optional>
#include <cstddef>
#include <string>
#include <vector>

#include "models.h"

namespace tugboat {
namespace engine {

// The capture boundary in surface logical pixels.
struct BoundaryRect {
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
};

// Where the host's time went (`capture.result.timings`), in microseconds.
// The screenshot budget charges them, as Dart's tracker does.
struct CaptureTimings {
  int64_t frame_wait_us = 0;
  int64_t readback_us = 0;
  int64_t mask_us = 0;
  int64_t encode_us = 0;

  int64_t total() const {
    return frame_wait_us + readback_us + mask_us + encode_us;
  }
};

// `capture.result.frame.maskCoverage.mode`: how much of the frame the
// host's masks cover. `precise` masks individual regions; `wholeHost` masks
// a toolkit host view whole (the Compose default); `wholeFrame` masks the
// whole frame (the host could not enumerate the screen with confidence).
enum class MaskMode {
  kPrecise,
  kWholeHost,
  kWholeFrame,
};

// `capture.result.frame.maskCoverage.reasons[]`: why the host masked what
// it did beyond individual text and media regions. Covers every value the
// Android (`MaskCoverageReason`) and SwiftUI (`MaskCoverage.Reason`)
// adapters emit, plus names reserved for the Views host.
enum class MaskReason {
  kComposeDefault,
  kComposeVersionUnverified,
  kComposeOwnerUnavailable,
  kInterop,
  kRegionUnreadable,
  kTreeUnreadable,
  kAnimating,
  kUnverifiedLayerAllowlist,
  kWalkExhausted,
  kNoWindowSize,
  kNoDecor,
  kRepresentable,
  kWebView,
  kRenderer,
  kSurfaceLayer,
  kUnclassifiedLayer,
  kSecureText,
};

// At most this many reasons, each at most once.
constexpr size_t kMaxMaskReasons = 8;

const char* mask_mode_name(MaskMode mode);
std::optional<MaskMode> parse_mask_mode(const std::string& name);
const char* mask_reason_name(MaskReason reason);
std::optional<MaskReason> parse_mask_reason(const std::string& name);

// Which mask mode applied to a frame, and why. Native hosts report it so a
// whole-masked host can be told from a broken capture. The engine records
// it as a `capture_diagnostic` (component `capture_masking`) when it
// accepts the frame; frame records and `frameMetadata` never carry it.
struct MaskCoverage {
  MaskMode mode = MaskMode::kPrecise;
  std::vector<MaskReason> reasons;  // distinct, in the host's order
};

// A frame the host captured (`capture.result.frame` plus `boundaryRect`).
// The bytes stay in the host under `handle`. `dhash` and
// `structure_signature` are opaque tokens the engine only compares.
struct CapturedFrame {
  std::string handle;
  int64_t width = 0;
  int64_t height = 0;
  std::string content_hash;
  OptString dhash;
  OptString structure_signature;
  bool masked = false;
  int64_t byte_length = 0;
  int64_t capture_micros = 0;
  OptString requested_backend;
  OptString resolved_backend;
  OptString fallback_reason;
  std::optional<MaskCoverage> mask_coverage;
  std::optional<BoundaryRect> boundary;
};

// Dart `ScreenshotCaptureFailure` without `cancelled` (an outcome of its
// own): why a `failed` capture produced no frame. `secureWindow` has no
// Dart counterpart: a native host never copies a window flagged secure
// (Android `FLAG_SECURE`).
enum class CaptureFailure {
  kBoundaryUnavailable,
  kBoundaryDetached,
  kBoundaryReplaced,
  kLayoutUnavailable,
  kPaintTimedOut,
  kPaintNotAdvanced,
  kReadbackFailed,
  kMaskFailed,
  kEncodingFailed,
  kSecureWindow,
};

const char* capture_failure_name(CaptureFailure failure);
std::optional<CaptureFailure> parse_capture_failure(const std::string& name);

// The `capture.result` outcomes the host reports.
enum class CaptureResultOutcome {
  kCaptured,
  kPaintUnchanged,
  kFailed,
  kCancelled,
};

// `capture.result {requestId, outcome, frame?, boundaryRect?, failure?,
// timings?}`.
struct CaptureResult {
  std::string request_id;
  CaptureResultOutcome outcome = CaptureResultOutcome::kFailed;
  std::optional<CapturedFrame> frame;      // with `captured` only
  std::optional<CaptureFailure> failure;   // with `failed` only
  std::optional<CaptureTimings> timings;
};

// Who consumes a capture answer. `key` is the interaction id (tap settle,
// gesture), the scroll start id (scroll end), the event id (focus or
// system-input observation), or the route epoch (route finalize). `kNone`
// captures (initial, lifecycle, scroll screenshots) only add frames.
struct CaptureOwner {
  enum class Kind { kNone, kTapSettle, kGesture, kScrollEnd, kObservation,
                    kRoute };
  Kind kind = Kind::kNone;
  std::string key;
};

// Dart `_CaptureOutcome`: the closed, privacy-safe resolution vocabulary.
enum class CaptureOutcome {
  kFreshAccepted,
  kExactContentReused,
  kPerceptualHashCoalesced,
  kPaintGenerationUnchanged,
  kScreenshotBudgetSkip,
  kCapturePressureDrop,
  kNoFrameAvailable,
  kNoCompatibleFrame,
  kPaintReadinessTimeout,
  kBoundaryUnavailable,
  kCaptureProcessingFailed,
  kCancelled,
  kSupersededRoute,
};

// `fresh_accepted`, …, `superseded_route_epoch`.
const char* capture_outcome_name(CaptureOutcome outcome);

// Dart's allowed cancellation reasons (`_cancelledCaptureExecution`).
enum class CancelReason {
  kDispose,
  kSessionEnd,
  kSessionReplacement,
  kLifecycleDeactivate,
  kSupersededRoute,
  kRouteTimeout,
  kRouteTransition,
  kCapturePressure,
};

const char* cancel_reason_name(CancelReason reason);

// What one logical capture request resolved to (Dart `_CaptureResolution`,
// reduced to what owners read; diagnostics read the rest when it resolves).
struct CaptureResolution {
  std::string request_id;  // `capture_request-N`
  CaptureOutcome outcome = CaptureOutcome::kCancelled;
  OptString frame_id;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_CAPTURE_TYPES_H
