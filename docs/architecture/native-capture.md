# Native capture architecture

Native CPU capture is an experimental Android path. Flutter still owns
scheduling, mask discovery, capture scale, and session/frame publication.

```text
Dart ScreenshotCapturer
  → mask collect (CaptureBoundary local space)
  → ScreenshotPixelSource
       FlutterRepaintBoundaryPixelSource   (default)
       NativeCpuExperimentalPixelSource    (opt-in; falls back)
            Pigeon NativeCaptureHostApi
              Android CaptureRuntime
                PixelCopy → C++ core → platform JPEG → SHA-256
```

Raw pixels never enter Dart. The C++ core fills masks before dHash and
before JPEG. Coverage on the first Android path is `engineSurface` only.

Behavioral rules live in
[native-capture-contracts.md](native-capture-contracts.md). Scope lives in
[repository-scope.md](repository-scope.md). Integration for host apps:
[native-cpu-experimental.md](../integration/native-cpu-experimental.md).
