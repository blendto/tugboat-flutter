# Apple TugboatCaptureRuntime

The version is `s.version` in the root `TugboatCaptureRuntime.podspec`
(ADR 0008); `docs/releases/compatibility.md` lists each one.

## 0.2.0

Unpublished. Additive; the existing `capture(view:request:onComplete:)` path
is unchanged and the Flutter plugin still pins `0.1.1`.

- `capture(view:request:maskSupplier:onComplete:)`: the supplier runs on the
  main thread after `layoutIfNeeded` and immediately before each draw
  attempt (`drawHierarchy` or `render(in:)`), in the same main-thread turn,
  so the masks describe the drawn layout. It returns a `MaskSnapshot`
  (masks normalized to the view, `wholeFrame`, the caller's
  `structureSignature`, and a caller `id` the runtime never reads).
  `request.masks` is ignored. A `wholeFrame` snapshot, or a drawn frame
  without a snapshot, is masked whole. Each draw keeps its own snapshot: a
  retried `afterScreenUpdates` draw has its own, and the incomplete
  fallback keeps the first draw's.
- `CaptureRequest.lastStructureSignature`: with a supplier, the dHash skip
  uses `lastDHash` only when this and the snapshot's signature are both
  non-empty and equal.
- `CaptureRequest.pixelsPerPoint`: when greater than 0, the bitmap is the
  view's bounds read in the draw turn times this ratio, so size, layout
  and masks come from one reading.
- `CaptureResult.maskSnapshot`: the snapshot of the draw the frame came
  from.
- `CaptureTimings.maskComputeMicros`: time spent in the supplier.

No new `CaptureStatus` or `CaptureCoverage` cases: exhaustive switches in
existing callers keep compiling.

## 0.1.1

Rejects transparent and near-white captures and validates explicit
view-hierarchy capture before encoding.

## 0.1.0

CocoaPods trunk / SwiftPM git tag; iOS 15 live Flutter-layer CPU path.
