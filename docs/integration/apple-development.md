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
| `sdks/flutter/packages/tugboat/ios` | Pigeon plugin; depends on the CocoaPod |

Do not copy `core/image-processing` into the pub package. The Flutter example
uses a local CocoaPods path override:

```ruby
pod 'TugboatCaptureRuntime', :path => File.expand_path('../../../../../../', File.dirname(__FILE__))
```

in `sdks/flutter/packages/tugboat/example/ios/Podfile`.

## Capture

The default runtime renders the live Flutter layer with
`view.layer.render(in:)` into a BGRA bitmap whose size is the Dart request
(`pixelWidth` × `pixelHeight`). Flutter's live layer delegate rerenders the
last Flutter layer tree, so Metal content is present. Coverage is
`engineSurface`. Embedded UIKit platform views are not guaranteed.

Native Apple integrations can initialize `CaptureRuntime` with
`captureMode: .viewHierarchy`. That compatibility mode uses
`drawHierarchy(in:afterScreenUpdates: false)`, reports `viewHierarchy`, and
sets `incomplete` when the draw returns false. The Flutter plugin uses the
default engine-surface mode.

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

Do not publish `TugboatCaptureRuntime` 0.1.0 until device privacy rows pass.
The live-layer path uses Flutter's existing Metal readback. It does not call
private Flutter selectors directly.
