import Foundation

public struct CaptureCapabilities {
  public let nativeCaptureSupported: Bool
  public let apiLevel: Int
  public let minNativeApi: Int

  public init(
    nativeCaptureSupported: Bool,
    apiLevel: Int,
    minNativeApi: Int = CaptureRuntime.minNativeApi
  ) {
    self.nativeCaptureSupported = nativeCaptureSupported
    self.apiLevel = apiLevel
    self.minNativeApi = minNativeApi
  }
}

public enum CaptureStatus {
  case ok
  case skippedByDHash
  case unsupportedApi
  case unsupportedRenderMode
  case surfaceUnavailable
  case timeout
  case pixelCopyFailed
  case processingFailed
  case cancelled
  case disposed
}

public enum CaptureCoverage {
  case engineSurface
  case viewHierarchy
}

public enum RenderMode {
  case surfaceView
  case textureView
  case hybrid
  case unknown
}

public struct NormalizedMask {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct CaptureRequest {
  public let requestId: Int64
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let force: Bool
  public let lastDHash: String
  /// Ignored when a mask supplier provides the masks.
  public let masks: [NormalizedMask]
  /// The visible structure `lastDHash` was captured with. With a mask
  /// supplier, the dHash skip uses `lastDHash` only when this and the
  /// supplied `MaskSnapshot.structureSignature` are both non-empty and
  /// equal; an unknown structure never skips.
  public let lastStructureSignature: String
  /// When greater than 0, the bitmap is the view's bounds read in the draw
  /// turn times this ratio (rounded up), and `pixelWidth` / `pixelHeight`
  /// are ignored; 0 keeps the fixed size.
  public let pixelsPerPoint: Double

  public init(
    requestId: Int64,
    pixelWidth: Int,
    pixelHeight: Int,
    force: Bool,
    lastDHash: String = "",
    masks: [NormalizedMask] = [],
    lastStructureSignature: String = "",
    pixelsPerPoint: Double = 0
  ) {
    self.requestId = requestId
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.force = force
    self.lastDHash = lastDHash
    self.masks = masks
    self.lastStructureSignature = lastStructureSignature
    self.pixelsPerPoint = pixelsPerPoint
  }
}

public struct CaptureTimings {
  public let surfaceCopyMicros: Int64
  public let maskFillMicros: Int64
  public let dHashMicros: Int64
  public let jpegMicros: Int64
  public let sha256Micros: Int64
  public let pixelReadbackMicros: Int64
  /// Time the mask supplier took on the main thread (0 without one).
  public let maskComputeMicros: Int64

  public init(
    surfaceCopyMicros: Int64 = 0,
    maskFillMicros: Int64 = 0,
    dHashMicros: Int64 = 0,
    jpegMicros: Int64 = 0,
    sha256Micros: Int64 = 0,
    pixelReadbackMicros: Int64 = 0,
    maskComputeMicros: Int64 = 0
  ) {
    self.surfaceCopyMicros = surfaceCopyMicros
    self.maskFillMicros = maskFillMicros
    self.dHashMicros = dHashMicros
    self.jpegMicros = jpegMicros
    self.sha256Micros = sha256Micros
    self.pixelReadbackMicros = pixelReadbackMicros
    self.maskComputeMicros = maskComputeMicros
  }
}

public struct CaptureResult {
  public let requestId: Int64
  public let status: CaptureStatus
  public let coverage: CaptureCoverage?
  public let jpeg: Data
  public let width: Int
  public let height: Int
  public let dHash: String
  public let contentHash: String
  public let timings: CaptureTimings
  public let renderMode: RenderMode
  public let incomplete: Bool
  /// What a supplied capture was masked with (the supplier's snapshot for
  /// the drawn frame, or `MaskSnapshot.failClosed`); nil without a supplier
  /// or when nothing was drawn.
  public let maskSnapshot: MaskSnapshot?

  public init(
    requestId: Int64,
    status: CaptureStatus,
    coverage: CaptureCoverage? = nil,
    jpeg: Data = Data(),
    width: Int = 0,
    height: Int = 0,
    dHash: String = "",
    contentHash: String = "",
    timings: CaptureTimings = CaptureTimings(),
    renderMode: RenderMode = .unknown,
    incomplete: Bool = false,
    maskSnapshot: MaskSnapshot? = nil
  ) {
    self.requestId = requestId
    self.status = status
    self.coverage = coverage
    self.jpeg = jpeg
    self.width = width
    self.height = height
    self.dHash = dHash
    self.contentHash = contentHash
    self.timings = timings
    self.renderMode = renderMode
    self.incomplete = incomplete
    self.maskSnapshot = maskSnapshot
  }
}
