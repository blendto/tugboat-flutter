# CPU capture device results

Production gates still require **release** builds on physical mid-range and
flagship devices. Do not treat the emulator numbers below as those gates.

`nativeCpuExperimental` remains opt-in (P7.39).

## Production device table

Fill one row per device class after following
[cpu-capture-method.md](cpu-capture-method.md). Percentiles are microseconds
unless noted. Leave cells blank rather than inventing numbers.

| Device class | Backend | Scenario | n | p50 | p90 | p95 | worst | UI-isolate p95 | peak RSS | dropped frames | JPEG bytes | Gate |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| mid-range | flutterRepaintBoundary | — | | | | | | | | | | not run |
| mid-range | nativeCpuExperimental | — | | | | | | | | | | not run |
| flagship | flutterRepaintBoundary | — | | | | | | | | | | not run |
| flagship | nativeCpuExperimental | — | | | | | | | | | | not run |

Failed device classes: none recorded (no physical release runs).

Battery (idle vs active, 10 minutes): not run.

## Emulator debug A/B (not a gate)

Recorded against PR head `ff8c3d54d848d5b6c1fbc481b9e24d0f6db7eaac` by
Chinmay Kabi, 2026-09-01. Same running AVD, same app; only
`screenshotCaptureBackend` changed.

- AVD `device_api35`, API 35, ARM64, `1080×2400` density 420
- Host `gfxstream` / `surfaceView`
- Flutter **debug** ARM64 APK
- Output `276×613` at pixel ratio `0.67`
- 30 warm-up + 200 measured **forced** captures
- Screenshot budget skipping disabled
- Two `TugboatSensitive` masks, identical screens

End-to-end **wall** latency (valid backend comparison):

| Metric | Native CPU | Flutter RepaintBoundary |
| --- | ---: | ---: |
| Average | 16.977 ms | 46.732 ms |
| p50 | 16.843 ms | 47.784 ms |
| p90 | 20.959 ms | 55.096 ms |
| p95 | 21.834 ms | 56.889 ms |
| Worst | 29.198 ms | 63.434 ms |

Native was 2.75× faster on average and 2.61× faster at p95 (61.6% p95
reduction). Requested and resolved `nativeCpuExperimental`,
`coverage=engineSurface`, `renderMode=surfaceView`, no Flutter fallback.

Average stage diagnostics:

| Stage | Native CPU | Flutter RepaintBoundary |
| --- | ---: | ---: |
| Frame wait | 7.152 ms | 11.156 ms |
| Mask collection | 3.067 ms | 3.124 ms |
| Surface copy | 3.317 ms | N/A |
| Flutter readback | N/A | 1.620 ms |
| Flutter encode pipeline | N/A | 29.984 ms |
| Native dHash | 0.133 ms | included above |
| Native JPEG | 0.828 ms | included above |
| Native SHA-256 | 0.199 ms | included above |
| Native mask fill | 0.001 ms | included above |
| Platform-channel round trip | 5.859 ms | N/A |

Native JPEG 5,738 bytes vs Flutter 10,556 bytes (45.6% smaller) at quality 80.

At that commit, native `TugboatFrame.captureMicros` averaged 20.560 ms because
`encodeMicros` added nested native stages on top of `platformChannel`. Those
intervals overlap. Wall latency is the valid comparison. The adapter now sets
native `encodeMicros` to `platformChannel` only.

### Privacy on this emulator run

Both backends reported `masked=true`. Decoded JPEG interior samples:

| Sample | Native RGB | Flutter RGB |
| --- | --- | --- |
| Top-left mask | `(25, 26, 26)` | `(26, 26, 26)` |
| Bottom-right mask | `(26, 27, 25)` | `(26, 26, 26)` |
| Unmasked red control | `(254, 0, 0)` | `(254, 0, 0)` |

JPEG SHA-256:

- Native: `18252c9a277c7e096ea0259bea4276e0673035222eaee84304d451d63c0024f9`
- Flutter: `d8ee8aa83bb6260f9694308d254de4917f2d24a66fb699845b03aa4ef1cb9b18`

This does not close rotation / scale / density / keyboard / inset device rows
or the production performance gate.

## iOS Simulator engine-surface proof (not a gate)

Recorded against PR head `e7cade4fd6471f174a85fbf6f883cb570352c206` by
Chinmay Kabi, 2026-09-01. The test used an iPhone 17 Pro Simulator on iOS
26.5. It called the Apple Pigeon capture API directly in a Flutter debug app.
The direct wall time does not include the SDK frame wait or Dart mask
collection.

The live Flutter-layer path captured visible Flutter Metal content and two
black masks. The proof JPEG was `270×586`, 21,078 bytes, with SHA-256
`223f3f21c7c507617547a0c3a1fe21aa3cecb07b4fd4a8a3fc363fc1538ee1c0`.
The result reported `status=ok`, `coverage=engineSurface`, and
`incomplete=false`.

Static capture used 30 warm-up captures and 200 measured captures:

| Metric | Live Flutter layer |
| --- | ---: |
| Wall average | 7.179 ms |
| Wall p50 | 7.134 ms |
| Wall p95 | 7.603 ms |
| Wall worst | 8.033 ms |
| Surface-copy average | 5.335 ms |
| Surface-copy p95 | 5.676 ms |
| Failures | 0 |

The scroll test moved through 5,000 rows by 12,000 points over 8 seconds. It
made 60 captures during the scroll:

| Metric | Live Flutter layer |
| --- | ---: |
| Capture wall average | 11.896 ms |
| Capture wall p95 | 13.485 ms |
| Surface-copy average | 8.192 ms |
| Surface-copy p95 | 9.255 ms |
| Frames | 482 |
| Frame-time p95 | 23.731 ms |
| Frames over 33.33 ms | 0 |
| Capture failures | 0 |

The two no-capture baselines rendered 481 and 482 frames. Their frame-time
p95 values were 21.978 ms and 22.018 ms. The prior `drawHierarchy` stage used
36.090 ms for static surface copy and 34.329 ms during scroll. The live-layer
path reduced those stages by 85.2% and 76.1%.

These are debug Simulator measurements. They do not close the physical-device
release gate. The engine-surface mode also does not guarantee embedded UIKit
platform-view content.
