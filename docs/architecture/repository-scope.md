# Mobile repository scope

Status: accepted for the native CPU capture work
Date: 2026-08-31

This repository becomes a mobile capture monorepo. Flutter remains the first
adapter. Native runtimes and a portable C++ core are first-class products, not
implementation details of `package:tugboat`.

The GitHub rename to `tugboat-mobile` still needs administrator access.
Until then the remote remains `tugboat-flutter`. Local trees already use
the monorepo layout.

## What this repository owns

| Tree | Product | First milestone |
| --- | --- | --- |
| `core/image-processing` | Portable C++ CPU core | Yes |
| `platforms/android/capture-runtime` | Android AAR `com.gettugboat.sdk:capture-runtime` | Yes |
| `platforms/apple` | Swift/ObjC++ runtime | Yes (experimental iOS CPU; unpublished) |
| `sdks/flutter` | Flutter adapter (`tugboat`, `tugboat_dio`) | Yes (opt-in native Android) |
| `sdks/react-native` | Future adapter placeholder | README only |

Adapters never vendor a copy of the C++ core. Files above a published pub
package are not part of that package archive.

## Common core scope

The core is a static library with a versioned C ABI. It is the only place
that validates pixel buffers, clips masks, paints opaque fills, converts to
grayscale, computes the 9×8 dHash, and decides dHash skips.

In scope:

- C++17, no C++ types in the public header
- RGBA8888 and BGRA8888 input, integer mask rectangles in bitmap pixels
- Explicit status codes; exceptions do not cross the ABI
- Stage timings for mask fill and dHash
- Thread-safety documented as: one buffer is not processed concurrently

Out of scope for the first core:

- JPEG encode/decode
- SHA-256
- Surface capture, `PixelCopy`, view hierarchy, lifecycle
- GPU shaders, Vulkan, Metal, OpenGL ES
- Networking, sessions, Dart, Kotlin, Swift

## Android runtime scope

Kotlin library `com.tugboat.capture` / namespace
`com.tugboat.capture.runtime`. Artifact
`com.gettugboat.sdk:capture-runtime:0.1.0`.

In scope:

- Capability probe, one serialized capture queue, cancellation, disposal
- Discover `FlutterSurfaceView`, reject other render modes with a status
- `PixelCopy` into a mutable bitmap, NDK lock, call the C ABI, unlock on
  every path
- Skip JPEG after a dHash skip; otherwise Android JPEG quality 80 + SHA-256
- Return only masked JPEG bytes and bounded metadata
- Local Maven publication for the native Android sample
- Hosted GitHub Packages publication on `capture-runtime-v*` tags

Capture scale stays Dart-owned. The adapter sends the bitmap width and
height that the current capturer would have used. The runtime serializes
captures: one in flight, including across different buffers.

API 24 is the native capture floor. Older Flutter-supported devices use the
Dart `RepaintBoundary` path. The first source is the Flutter engine surface,
not a window composite.

## Apple runtime scope

Swift module / CocoaPod `TugboatCaptureRuntime` 0.1.0. The default path renders
the live Flutter layer into a native bitmap. The compatibility path uses
`drawHierarchy(in:afterScreenUpdates:)`. Both use the same C++ core, ImageIO
JPEG, and SHA-256. Root `Package.swift` and
`TugboatCaptureRuntime.podspec` stay at the repository root.

The Flutter Apple plugin captures the Flutter engine surface (`engineSurface`
coverage). It is experimental and unpublished. iOS 15 is the native floor;
older OS versions report `unsupportedApi` and Flutter falls back.

## Flutter adapter scope

`package:tugboat` stays the public Dart API. First native-capable version is
planned as `0.9.0`. This Phase 0/1 line is `0.8.13` and does not enable
native capture.

In scope for the Android and Apple CPU betas:

- Plugin metadata, Pigeon `getCapabilities` / `capture` / `dispose`
- `TugboatScreenshotCaptureBackend`: `flutterRepaintBoundary` (default) and
  `nativeCpuExperimental`
- Send mask metadata and previous dHash; receive masked JPEG only
- Automatic fallback; never publish native and Flutter results for one request
- Preserve session schema, frame transport, scheduling, and mask policy
- Android: the Flutter plugin compiles `capture-runtime` from source in the
  monorepo. Native Android apps use the local Maven AAR or the hosted
  GitHub Packages / Maven Central coordinate. iOS: the
  plugin compiles `TugboatCaptureRuntime` sources; the root CocoaPod remains
  for native Apple apps.

`TugboatCaptureBoundary` stays. Flutter may still supply mask geometry and
capture scheduling.

## Future React Native adapter scope

Placeholder only: Android namespace `com.tugboat.reactnative`, npm
`@tugboat/react-native`. It will consume the same AAR and CocoaPod. Raw
pixels must never enter JavaScript. No npm workspace in the first milestone.
