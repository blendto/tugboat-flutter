import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/native_capture.g.dart',
    dartOptions: DartOptions(),
    dartPackageName: 'tugboat',
    kotlinOut: 'android/src/main/kotlin/com/tugboat/flutter/NativeCapture.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.tugboat.flutter'),
    swiftOut: 'ios/Classes/NativeCapture.g.swift',
    swiftOptions: SwiftOptions(),
  ),
)
enum NativeCaptureStatus {
  ok,
  skippedByDHash,
  unsupportedApi,
  unsupportedRenderMode,
  surfaceUnavailable,
  timeout,
  pixelCopyFailed,
  processingFailed,
  cancelled,
  disposed,
}

enum NativeCaptureCoverage { engineSurface, windowComposite, viewHierarchy }

enum NativeCaptureRenderMode { surfaceView, textureView, hybrid, unknown }

class NativeCaptureMask {
  late double x;
  late double y;
  late double width;
  late double height;
}

class NativeCaptureTimings {
  late int surfaceCopyMicros;
  late int maskFillMicros;
  late int dHashMicros;
  late int jpegMicros;
  late int sha256Micros;
  late int pixelReadbackMicros;
}

class NativeCaptureCapabilities {
  late bool nativeCaptureSupported;
  late int apiLevel;
  late int minNativeApi;
}

class NativeCaptureRequest {
  late int requestId;
  late int pixelWidth;
  late int pixelHeight;
  late bool force;
  late String lastDHash;
  late List<NativeCaptureMask> masks;
}

class NativeCaptureResult {
  late int requestId;
  late NativeCaptureStatus status;
  NativeCaptureCoverage? coverage;
  late Uint8List jpeg;
  late int width;
  late int height;
  late String dHash;
  late String contentHash;
  late NativeCaptureTimings timings;
  late NativeCaptureRenderMode renderMode;
  late bool incomplete;
}

@HostApi()
abstract class NativeCaptureHostApi {
  NativeCaptureCapabilities getCapabilities();

  @async
  NativeCaptureResult capture(NativeCaptureRequest request);

  void cancel(int requestId);

  void dispose();
}
