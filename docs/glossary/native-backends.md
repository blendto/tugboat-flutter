# Native backends

Status: current · Last verified: 2026-09-05

**Capture backend** — where screenshot pixels come from:

- **Default: Flutter `RepaintBoundary` screenshots** — the Dart-layer path,
  always available, masked in Dart before encode.
- **Native CPU capture** — experimental, opt-in
  (`TugboatScreenshotCaptureBackend.nativeCpuExperimental` on Android; the
  same opt-in flag drives a live Flutter-layer CPU path on iOS). Processes
  pixels in native code; raw pixels never cross into Dart.

**`engineSurface`** — the Android engine-layer surface used by native capture.
Known limits: it can return blank/invalid pixels on some devices; the capture
pipeline validates and rejects blank frames (see
`docs/architecture/capture-coverage.md`).

**Fallback** — the rule that a failing native capture falls back to the
default Dart path (see `docs/architecture/fallback.md` and the
Status × fallback × publish table in
`docs/architecture/native-capture-contracts.md`). Native frames are published
only when their status and privacy gates pass; otherwise the SDK falls back
silently.

**Gates for leaving experimental** — privacy device rows + the native capture
contracts + the experimental native CPU gates must all pass; both backends
stay experimental until then (first native-default adapter is planned for
Flutter `0.9.0`).
