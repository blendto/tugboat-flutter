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

The runtime draws the Flutter view with
`drawHierarchy(in:afterScreenUpdates: false)` into a BGRA bitmap whose size
is the Dart request (`pixelWidth` × `pixelHeight`). Coverage is
`viewHierarchy`. If `drawHierarchy` returns false, `incomplete` is true.
Masks and dHash go through the C++ core. JPEG is ImageIO quality 80.
SHA-256 is CryptoKit over the JPEG. Raw pixels never enter Dart.

`drawHierarchy` runs on the main thread. Mask fill, dHash, JPEG, and SHA-256
run on the serial `tugboat-capture` queue. Timeout is 2000 ms covering draw
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
Do not start Metal work before the CPU baseline exists
([gpu.md](../roadmap/gpu.md)).
