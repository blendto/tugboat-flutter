import Flutter
import TugboatCaptureRuntime

enum NativeCaptureMapping {
  static func capabilities(_ value: CaptureCapabilities) -> NativeCaptureCapabilities {
    NativeCaptureCapabilities(
      nativeCaptureSupported: value.nativeCaptureSupported,
      apiLevel: Int64(value.apiLevel),
      minNativeApi: Int64(value.minNativeApi)
    )
  }

  static func request(_ value: NativeCaptureRequest) -> CaptureRequest {
    CaptureRequest(
      requestId: value.requestId,
      pixelWidth: Int(value.pixelWidth),
      pixelHeight: Int(value.pixelHeight),
      force: value.force,
      lastDHash: value.lastDHash,
      masks: value.masks.map {
        NormalizedMask(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
      }
    )
  }

  static func result(_ value: CaptureResult) -> NativeCaptureResult {
    NativeCaptureResult(
      requestId: value.requestId,
      status: status(value.status),
      coverage: value.coverage.map(coverage),
      jpeg: FlutterStandardTypedData(bytes: value.jpeg),
      width: Int64(value.width),
      height: Int64(value.height),
      dHash: value.dHash,
      contentHash: value.contentHash,
      timings: timings(value.timings),
      renderMode: renderMode(value.renderMode),
      incomplete: value.incomplete
    )
  }

  static func failed(
    _ request: NativeCaptureRequest,
    _ status: NativeCaptureStatus
  ) -> NativeCaptureResult {
    NativeCaptureResult(
      requestId: request.requestId,
      status: status,
      jpeg: FlutterStandardTypedData(bytes: Data()),
      width: 0,
      height: 0,
      dHash: "",
      contentHash: "",
      timings: timings(CaptureTimings()),
      renderMode: .unknown,
      incomplete: false
    )
  }

  private static func status(_ value: CaptureStatus) -> NativeCaptureStatus {
    switch value {
    case .ok: return .ok
    case .skippedByDHash: return .skippedByDHash
    case .unsupportedApi: return .unsupportedApi
    case .unsupportedRenderMode: return .unsupportedRenderMode
    case .surfaceUnavailable: return .surfaceUnavailable
    case .timeout: return .timeout
    case .pixelCopyFailed: return .pixelCopyFailed
    case .processingFailed: return .processingFailed
    case .cancelled: return .cancelled
    case .disposed: return .disposed
    }
  }

  private static func coverage(_ value: CaptureCoverage) -> NativeCaptureCoverage {
    switch value {
    case .engineSurface: return .engineSurface
    case .viewHierarchy: return .viewHierarchy
    }
  }

  private static func renderMode(_ value: RenderMode) -> NativeCaptureRenderMode {
    switch value {
    case .surfaceView: return .surfaceView
    case .textureView: return .textureView
    case .hybrid: return .hybrid
    case .unknown: return .unknown
    }
  }

  private static func timings(_ value: CaptureTimings) -> NativeCaptureTimings {
    NativeCaptureTimings(
      surfaceCopyMicros: value.surfaceCopyMicros,
      maskFillMicros: value.maskFillMicros,
      dHashMicros: value.dHashMicros,
      jpegMicros: value.jpegMicros,
      sha256Micros: value.sha256Micros,
      pixelReadbackMicros: value.pixelReadbackMicros
    )
  }
}
