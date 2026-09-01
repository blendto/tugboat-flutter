import Foundation
import UIKit

/// Published-package stub. Native CPU capture compiles from monorepo sources
/// under `platforms/apple` when `NativeRuntime` resolves.
final class CaptureRuntime {
  static let minNativeApi: Int = 15
  static let defaultTimeoutMs: Int64 = 2_000

  init(timeoutMs: Int64 = CaptureRuntime.defaultTimeoutMs) {}

  func capabilities() -> CaptureCapabilities {
    let api = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return CaptureCapabilities(
      nativeCaptureSupported: false,
      apiLevel: api,
      minNativeApi: CaptureRuntime.minNativeApi
    )
  }

  func capture(view: UIView, request: CaptureRequest, onComplete: @escaping (CaptureResult) -> Void) {
    onComplete(CaptureResult(requestId: request.requestId, status: .unsupportedApi))
  }

  func cancel(requestId: Int64) {}

  func dispose() {}
}

struct CaptureCapabilities {
  let nativeCaptureSupported: Bool
  let apiLevel: Int
  let minNativeApi: Int
}

enum CaptureStatus {
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

enum CaptureCoverage {
  case engineSurface
  case viewHierarchy
}

enum RenderMode {
  case surfaceView
  case textureView
  case hybrid
  case unknown
}

struct NormalizedMask {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

struct CaptureRequest {
  let requestId: Int64
  let pixelWidth: Int
  let pixelHeight: Int
  let force: Bool
  let lastDHash: String
  let masks: [NormalizedMask]

  init(
    requestId: Int64,
    pixelWidth: Int,
    pixelHeight: Int,
    force: Bool,
    lastDHash: String = "",
    masks: [NormalizedMask] = []
  ) {
    self.requestId = requestId
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.force = force
    self.lastDHash = lastDHash
    self.masks = masks
  }
}

struct CaptureTimings {
  let surfaceCopyMicros: Int64
  let maskFillMicros: Int64
  let dHashMicros: Int64
  let jpegMicros: Int64
  let sha256Micros: Int64
  let pixelReadbackMicros: Int64

  init(
    surfaceCopyMicros: Int64 = 0,
    maskFillMicros: Int64 = 0,
    dHashMicros: Int64 = 0,
    jpegMicros: Int64 = 0,
    sha256Micros: Int64 = 0,
    pixelReadbackMicros: Int64 = 0
  ) {
    self.surfaceCopyMicros = surfaceCopyMicros
    self.maskFillMicros = maskFillMicros
    self.dHashMicros = dHashMicros
    self.jpegMicros = jpegMicros
    self.sha256Micros = sha256Micros
    self.pixelReadbackMicros = pixelReadbackMicros
  }
}

struct CaptureResult {
  let requestId: Int64
  let status: CaptureStatus
  let coverage: CaptureCoverage?
  let jpeg: Data
  let width: Int
  let height: Int
  let dHash: String
  let contentHash: String
  let timings: CaptureTimings
  let renderMode: RenderMode
  let incomplete: Bool

  init(
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
    incomplete: Bool = false
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
  }
}
