# Apple capture runtime

Swift module and CocoaPod `TugboatCaptureRuntime`; versions and history are
in the [CHANGELOG](CHANGELOG.md) (0.2.0 is unpublished). Experimental iOS 15
CPU path: render the live Flutter layer into a bitmap, C++ masks/dHash, and
ImageIO JPEG. Flutter's layer delegate preserves Metal content. The slower
`drawHierarchy` path remains available through `CaptureCoverage.viewHierarchy`
for UIKit platform-view compatibility.

`Package.swift` and `TugboatCaptureRuntime.podspec` live at the repository
root. The Flutter example path-overrides the CocoaPod to this repository.
`publish-apple.yml` pushes `0.1.0` to CocoaPods trunk.

See [apple-development.md](../../docs/integration/apple-development.md).

The native SwiftUI SDK (`Tugboat`) is in [Sources/Tugboat](Sources/Tugboat/README.md)
and its sample app in [Samples/TugboatSwiftUISample](Samples/TugboatSwiftUISample/README.md).
