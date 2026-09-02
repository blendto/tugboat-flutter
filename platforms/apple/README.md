# Apple capture runtime

Swift module and CocoaPod `TugboatCaptureRuntime` 0.1.0. Experimental iOS 15
CPU path: render the live Flutter layer into a bitmap, C++ masks/dHash, and
ImageIO JPEG. Flutter's layer delegate preserves Metal content. The slower
`drawHierarchy` path remains available through `CaptureCoverage.viewHierarchy`
for UIKit platform-view compatibility.

`Package.swift` and `TugboatCaptureRuntime.podspec` live at the repository
root. The Flutter example path-overrides the CocoaPod to this repository.
`publish-apple.yml` pushes `0.1.0` to CocoaPods trunk.

See [apple-development.md](../../docs/integration/apple-development.md).
