# CPU capture measurement method

Phase 7 device gates cannot close in this environment: there is no physical
Android device, and the example release APK currently fails Flutter 3.47's
Gradle 8.14 floor (see [cpu-capture-baseline.md](../../../docs/performance/cpu-capture-baseline.md)).
Native CPU capture stays experimental until a device lab fills
[cpu-capture-results.md](cpu-capture-results.md) from **release** builds.

Do not substitute host-only estimates, emulator numbers, or debug builds.

## What to measure

Use the stage names in
[native-capture-contracts.md](../../../docs/architecture/native-capture-contracts.md)
(clock ownership table) and
[cpu-capture-baseline.md](../../../docs/performance/cpu-capture-baseline.md). Native must not put
PixelCopy into Dart `captureMicros`.

| Stage | Where it is recorded |
| --- | --- |
| `frameWait` | Dart `ScreenshotCaptureAttempt.frameWaitMicros` |
| `maskCollect` | Dart `ScreenshotCaptureResult.maskMicros` |
| `surfaceCopy` | `ScreenshotBackendTrace.surfaceCopyMicros` (PixelCopy) |
| `pixelReadback` | `ScreenshotBackendTrace.pixelReadbackMicros` (0 after PixelCopy) |
| `maskFill` | `ScreenshotBackendTrace.maskFillMicros` |
| `dHash` | `ScreenshotBackendTrace.dHashMicros` |
| `jpeg` | `ScreenshotBackendTrace.jpegMicros` (0 on dHash skip) |
| `sha256` | `ScreenshotBackendTrace.sha256Micros` (0 on dHash skip) |
| `platformChannel` | `ScreenshotBackendTrace.platformChannelMicros` |
| `dartUiIsolate` | Flutter timeline / UI-isolate CPU during capture; native path should be near zero |
| end-to-end | Dart `TugboatFrame.captureMicros` (`frameWait + maskCollect + encodeMicros`). Native `encodeMicros` is `platformChannel` only. |
| peak transient memory | process RSS / Java heap around one capture (both backends) |
| process CPU | `/proc/self/stat` or Android Studio CPU profiler, capture window only |
| dropped Flutter frames | `SchedulerBinding` / systrace `Frame` skipped count during the same window |
| JPEG output size | bytes of published JPEG; compare to the baseline envelope |
| idle battery | same build, capture disabled, 10 minutes |
| active battery | same build, capture enabled, same 10 minutes |

`capture_diagnostic` events already carry the backend trace fields. Published
`TugboatFrame` records also include `requestedBackend`, `resolvedBackend`, and
`fallbackReason` (productionLean included). Collect those plus process metrics;
do not log JPEG or pixel buffers.

## Protocol

1. Install a **release** build of `sdks/flutter/packages/tugboat/example`.
2. Run each scenario twice on the same device: default
   `flutterRepaintBoundary`, then `nativeCpuExperimental`.
3. Warm up with at least 30 captures. Discard them.
4. Measure at least 200 captures per scenario per backend.
5. Report p50, p90, p95, and the worst observed value.
6. Repeat on a mid-range device and a recent flagship.

Scenarios: static screen, scrolling, image-heavy, many masks, rapid
navigation, keyboard visible, background transition, low memory.

Use `NativePrivacyFixtureScreen` for the many-masks case so privacy and
performance share a fixture.

## Gates

Keep `nativeCpuExperimental` opt-in unless **every** gate passes on **both**
device classes:

- ≥ 35% lower p95 processing time vs Flutter `RepaintBoundary`
- ≥ 60% lower Flutter UI-isolate screenshot work
- ≥ 25% lower peak transient memory
- no new dropped-frame regression
- no privacy regression ([native-cpu-signoff.md](native-cpu-signoff.md))
- JPEG quality 80, size inside the baseline envelope

Processing time for the gate is end-to-end `TugboatFrame.captureMicros` on
published frames (exclude dHash skips, or report them separately). Record each
device class that fails a gate. Do not change the default backend from a
host-only estimate.

Lab notes and the collection checklist live in
[tool/benchmarks/README.md](../../../tool/benchmarks/README.md).
