# Native capture architecture

Native CPU capture is an experimental opt-in path on Android and iOS. Flutter
still owns scheduling, mask discovery, capture scale, and session/frame
publication.

```text
Dart ScreenshotCapturer
  → mask collect (CaptureBoundary local space)
  → ScreenshotPixelSource
       FlutterRepaintBoundaryPixelSource   (default)
       NativeCpuExperimentalPixelSource    (opt-in; falls back)
            Pigeon NativeCaptureHostApi
              Android CaptureRuntime
                PixelCopy → C++ core → platform JPEG → SHA-256
              Apple CaptureRuntime
                CALayer.render → C++ core → ImageIO JPEG → SHA-256
```

Raw pixels never enter Dart. The C++ core fills masks before dHash and
before JPEG. Coverage on the first native path is `engineSurface`.
Physical iOS Metal coverage is still an open device-lab gate.

Behavioral rules live in
[native-capture-contracts.md](native-capture-contracts.md). Scope lives in
[repository-scope.md](repository-scope.md). Integration for host apps:
[native-cpu-experimental.md](../integration/native-cpu-experimental.md).
