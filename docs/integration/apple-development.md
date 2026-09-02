# Apple development

Experimental CPU path for iOS 15+. Default Flutter capture remains
`RepaintBoundary`. Native capture is opt-in
(`TugboatScreenshotCaptureBackend.nativeCpuExperimental`).

## Layout

| Path | Role |
| --- | --- |
| `Package.swift` | Root SwiftPM entry |
| `TugboatCaptureRuntime.podspec` | Root CocoaPod (version `0.1.0`) |
| `platforms/apple/Sources/TugboatCaptureRuntime` | Public Swift API |
| `platforms/apple/Sources/TugboatImageCoreBridge` | Objective-C++ bridge to the C ABI |
| `platforms/apple/Tests` | XCTest (MaskMapper, runtime constants) |
| `platforms/apple/Sample` | Usage notes, not a full Xcode app |
| `sdks/flutter/packages/tugboat/ios` | Pigeon plugin; depends on CocoaPods `TugboatCaptureRuntime` |

Do not copy `core/image-processing` into the published pub package. The
Flutter plugin depends on CocoaPods `TugboatCaptureRuntime` `0.1.0` and
requires iOS 15. The example app path-overrides the pod to this repository.
Native capture still reports unsupported below iOS 15 on devices that somehow
run a lower OS; hosts must set iOS 15 as the floor.

## Capture

The default runtime renders the live Flutter view with
`view.layer.render(in:)` into a BGRA bitmap whose size is the Dart request
(`pixelWidth` × `pixelHeight`). FlutterView implements `CALayerDelegate`,
which is intended to rerender the last Flutter layer tree into CPU-readable
memory. Core Graphics does not copy `CAMetalLayer` contents by itself, so
physical Metal coverage is still an open lab gate; simulator output is not
that gate. Coverage is reported as `engineSurface`. Embedded UIKit platform
views are not guaranteed.

Native Apple integrations can initialize `CaptureRuntime` with
`coverage: .viewHierarchy`. That compatibility mode uses
`drawHierarchy(in:afterScreenUpdates: false)`, reports `viewHierarchy`, and
sets `incomplete` when the draw returns false. The Flutter plugin uses the
default engine-surface coverage.

Masks and dHash go through the C++ core. JPEG is ImageIO quality 80. SHA-256
is CryptoKit over the JPEG. Raw pixels never enter Dart.

View capture runs on the main thread. Mask fill, dHash, JPEG, and SHA-256 run
on the serial `tugboat-capture` queue. Timeout is 2000 ms covering readback
plus processing. Status × fallback matches
[native-capture-contracts.md](../architecture/native-capture-contracts.md).

Public Swift surface golden: `platforms/apple/api.txt`
(`bash tool/ci/verify-swift-api.sh`).

## Build

Requires Xcode. This Linux CI host cannot compile for simulator or device.

```sh
swift test --package-path .  # needs Xcode / iOS SDK
```

`publish-apple.yml` pushes `TugboatCaptureRuntime` `0.1.0` to CocoaPods trunk
when `COCOAPODS_TRUNK_TOKEN` is set. The live-layer path uses Flutter's
existing Metal readback. It does not call private Flutter selectors directly.
