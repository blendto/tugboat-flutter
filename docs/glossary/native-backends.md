# Native backends

Status: current · Last verified: 2026-09-05

**Capture backend** — where screenshot pixels come from:

- **Default: Flutter `RepaintBoundary` screenshots** — the Dart-layer path,
  always available, masked in Dart before encode.
- **Native CPU capture** — experimental, opt-in
  (`TugboatScreenshotCaptureBackend.nativeCpuExperimental` on Android; the
  same opt-in flag drives a live Flutter-layer CPU path on iOS). Processes
  pixels in native code; raw pixels never cross into Dart.

**`engineSurface`** — the Android engine-layer surface used by native capture
(`PixelCopy` of the active `FlutterSurfaceView`). Coverage limits for missing
platform views, video/map surfaces, and DRM are in
`docs/architecture/capture-coverage.md`. Blank/near-white capture rejection is
an Apple runtime 0.1.1 behavior (`docs/releases/compatibility.md`), not a
general Android `engineSurface` limit.

**Fallback** — the rule that a failing native capture falls back to the
default Dart path (see `docs/architecture/fallback.md` and the
Status × fallback × publish table in
`docs/architecture/native-capture-contracts.md`). Native frames are published
only when their status and privacy gates pass; otherwise the SDK falls back
silently.

**Native CPU experimental status** — `nativeCpuExperimental` stays opt-in.
`flutterRepaintBoundary` is the production default (see
`docs/integration/native-cpu-experimental.md` and
`docs/architecture/fallback.md`). Android native CPU and the iOS live
Flutter-layer CPU path remain experimental until privacy lab gates and the
native capture contracts pass.
