# CPU capture baseline

This file is the public comparison contract (stage names, toolchain pins, JPEG
envelope). Device-lab method and results are internal working notes, not
shipping claims. Numbers below are not Phase 7 device p50/p95 gates.

Recorded 2026-08-31 against `main` `dfc816190c8e247366a74d367c75ae1ba447a434`.

Host: Linux x86_64, Flutter 3.47.2 / Dart 3.13.2. No physical Android or Apple
device. No Xcode.

Pipeline ownership, mask policy, dHash, JPEG quality, and platform-view limits
live in [capture-and-fingerprint.md](../design/capture-and-fingerprint.md).

## Comparison contract

Native CPU capture and the current Dart path must emit the same stages. Dart
clock *names* are not those stages. Do not put PixelCopy into Dart's
`captureMicros`, mask fill into Dart's `maskMicros`, or platform JPEG into
Dart's `encodeMicros` and call that a comparison.

| Stage | Current Dart mapping |
| --- | --- |
| `frameWait` | `ScreenshotCaptureAttempt.frameWaitMicros` |
| `surfaceCopy` | `ScreenshotCaptureResult.captureMicros` (`toImage` only) |
| `maskCollect` | `ScreenshotCaptureResult.maskMicros` (rects + scale, not fill) |
| `pixelReadback` | `toByteData(rawRgba)`, folded into `encodeMicros` |
| `maskFill` | In-place RGBA fill on the encode isolate, folded into `encodeMicros` |
| `dHash` | Folded into `encodeMicros` |
| `jpeg` | Folded into `encodeMicros`; omitted on dHash skip |
| `sha256` | Folded into `encodeMicros`; omitted on dHash skip |
| `dartUiIsolate` | `toImage` + `toByteData` + `TransferableTypedData` copy. Not a separate counter. |
| `platformChannel` | Not used. Capture is entirely Dart. |
| end-to-end | `TugboatFrame.captureMicros` = frame wait + the three result clocks |

On the native path, Dart `captureMicros` stays 0 and Dart `encodeMicros` is
the Pigeon `capture` round-trip only. Nested native stages belong on
`ScreenshotBackendTrace`. Adding them into `encodeMicros` double-counts work
already inside `platformChannel`.

Skip semantics:

- Paint-generation reuse: no readback; Dart clocks are zero.
- dHash skip: still pays `surfaceCopy` + `pixelReadback` + `maskFill` + `dHash`;
  `jpeg` and `sha256` do not run; Dart `encodeMicros` still includes the work
  that ran.

Memory native must beat: no raw pixels in Dart, no `TransferableTypedData`
RGBA copy. See the design doc. This file has **no Dart process RSS**. The
25% peak-transient-memory gate is a Phase 7 device-vs-device measurement of
both backends, not a comparison against this document.

JPEG envelope (quality 80, regenerate with
`cd sdks/flutter/packages/tugboat && flutter test test/replay/jpeg_size_envelope_test.dart`):

| Buffer class | Pixel recipe | JPEG / RGBA |
| --- | --- | --- |
| Solid | RGB `(32,64,128)` | `< 0.02` (observed ~0.008) |
| Deterministic noise | LCG in `JpegSizeEnvelope.noisyRgba` | `0.30`–`0.40` (observed ~0.35) |
| 8×8 unit fixture | same solid fill | `> 1` (headers dominate; do not use for codec comparison) |

Buffers are typical logical phone sizes × `capturePixelRatio` 0.75, rounded:
360×800 → 270×600, 390×844 → 293×633, 430×932 → 323×699. They are not
`captureMaxWidth` defaults (`captureMaxWidth` is unset). Real UI photographs
sit between the solid and noise bands.

## Toolchain pins

The C++ core and Android AAR should compile with the NDK/CMake Flutter already
pins, not with the host desktop toolchain.

| Pin | Value |
| --- | --- |
| Flutter default NDK | 28.2.13676358 (r28c), clang 19.0.1 |
| Android SDK CMake | 3.22.1 |
| AGP (example) | 8.11.1 |
| Kotlin plugin (example) | 2.2.20 |
| Gradle wrapper (example) | 8.14 |
| Flutter min Gradle (3.47.2) | 8.14.0 |
| Example min / compile SDK | min 24, compile/target 36 |
| Package constraints | Dart `^3.9.2`, Flutter `>=3.35.0` |
| tugboat | 0.8.12 (capture path unchanged from 0.8.11) |

Host CMake 3.28.3 and host clang 18.1.3 were present on the lab machine. They
are not the Android compile pin.

## Dated lab note

- Format: pass (`dart format --output=none --set-exit-if-changed .`).
- Analyzer: pass (`dart analyze .`).
- Tests: pass (367 tugboat, 20 tugboat_dio).
- `dart pub get` succeeded. Flutter 3.47.2 also rewrote SDK pins in
  `pubspec.lock` and injected `analyzer.exclude` / `android.newDsl=false`.
  Those mutations were reverted.

Unresolved Apple floor: the example now sets iOS 15.0 to match Flutter
3.47 and the native capture floor. Simulator/device Xcode builds are still
unrun in this environment.

## Packaging and CI debt

These are not native-capture comparison gates.

- **Example APK:** wrapper is Gradle 8.14 / AGP 8.11.1 / Kotlin 2.2.20 to meet
  Flutter 3.47's floor. Confirm `flutter build apk --release` on a machine
  with that Flutter SDK. This VM may not have Flutter installed.
- **Complexity gate:** `dallow 0.2.1` crashes on Dart 3.13
  (`Missing implementation of visitDotShorthandPropertyAccess`). `dart analyze`
  is clean; the complexity script cannot run on this toolchain until dallow
  (or its analyzer) is upgraded.
