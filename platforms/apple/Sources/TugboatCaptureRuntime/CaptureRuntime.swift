import Foundation
import UIKit
#if SWIFT_PACKAGE
import TugboatImageCoreBridge
#endif

// The C ABI fixes BGRA8888 to raw value 2. Swift 6.3 does not expose the
// TBPixelFormatBGRA8888 enumerator by name through this mixed C++ target.
private let tbBgra8888PixelFormat = TBPixelFormat(rawValue: 2)!

public final class CaptureRuntime {
  public static let minNativeApi: Int = 15
  public static let defaultTimeoutMs: Int64 = 2_000
  public static let jpegQuality: Int = 80

  private static let noRequest: Int64 = -1

  private let timeoutMs: Int64
  private let captureMode: AppleCaptureMode
  private let queue = DispatchQueue(label: "tugboat-capture")
  private let stateLock = NSLock()
  private var disposed = false
  private var inFlightId: Int64 = CaptureRuntime.noRequest
  private var cancelledId: Int64 = CaptureRuntime.noRequest

  public init(
    timeoutMs: Int64 = CaptureRuntime.defaultTimeoutMs,
    captureMode: AppleCaptureMode = .engineSurface
  ) {
    self.timeoutMs = timeoutMs
    self.captureMode = captureMode
  }

  public func capabilities() -> CaptureCapabilities {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let api = version.majorVersion
    return CaptureCapabilities(
      nativeCaptureSupported: api >= CaptureRuntime.minNativeApi,
      apiLevel: api
    )
  }

  public func capture(view: UIView, request: CaptureRequest, onComplete: @escaping (CaptureResult) -> Void) {
    if isDisposed {
      onComplete(result(request, .disposed))
      return
    }
    queue.async { [weak self] in
      guard let self else {
        onComplete(
          CaptureResult(requestId: request.requestId, status: .disposed)
        )
        return
      }
      self.setInFlight(request.requestId)
      let outcome = self.captureSync(view: view, request: request)
      self.clearInFlight(request.requestId)
      onComplete(outcome)
    }
  }

  public func cancel(requestId: Int64) {
    stateLock.lock()
    cancelledId = requestId
    stateLock.unlock()
  }

  public func dispose() {
    stateLock.lock()
    disposed = true
    stateLock.unlock()
  }

  private func captureSync(view: UIView, request: CaptureRequest) -> CaptureResult {
    if isDisposed { return result(request, .disposed) }
    if isCancelled(request.requestId) { return result(request, .cancelled) }
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < CaptureRuntime.minNativeApi {
      return result(request, .unsupportedApi)
    }
    if request.pixelWidth <= 0 || request.pixelHeight <= 0 {
      return result(request, .processingFailed)
    }

    let started = DispatchTime.now()
    var bitmap: NativeBitmap?
    let draw: () -> Void = {
      bitmap = AppleViewCapture.capture(
        view: view,
        pixelWidth: request.pixelWidth,
        pixelHeight: request.pixelHeight,
        mode: self.captureMode
      )
    }
    if Thread.isMainThread {
      draw()
    } else {
      DispatchQueue.main.sync(execute: draw)
    }
    let surfaceCopyMicros = elapsedMicros(from: started)
    if !isCurrent(request.requestId) {
      return result(request, .cancelled)
    }
    if timedOut(from: started) {
      return result(request, .timeout).withTimings(
        CaptureTimings(surfaceCopyMicros: surfaceCopyMicros)
      )
    }
    guard let bitmap else {
      if view.bounds.width <= 0 || view.bounds.height <= 0 {
        return result(request, .surfaceUnavailable)
      }
      return result(request, .pixelCopyFailed).withTimings(
        CaptureTimings(surfaceCopyMicros: surfaceCopyMicros)
      )
    }

    let masks = MaskMapper.toPixelRects(
      masks: request.masks,
      width: bitmap.width,
      height: bitmap.height
    )
    let processed = process(bitmap: bitmap, masks: masks, request: request)
    if timedOut(from: started) {
      return result(request, .timeout).withTimings(
        CaptureTimings(
          surfaceCopyMicros: surfaceCopyMicros,
          maskFillMicros: processed.maskFillMicros,
          dHashMicros: processed.dHashMicros
        )
      )
    }
    let coreStatus = mapCoreStatus(processed.status)
    if coreStatus != .ok && coreStatus != .skippedByDHash {
      return result(request, coreStatus)
    }
    if coreStatus == .skippedByDHash {
      return CaptureResult(
        requestId: request.requestId,
        status: .skippedByDHash,
        coverage: captureMode.coverage,
        width: bitmap.width,
        height: bitmap.height,
        dHash: processed.dHash,
        timings: CaptureTimings(
          surfaceCopyMicros: surfaceCopyMicros,
          maskFillMicros: processed.maskFillMicros,
          dHashMicros: processed.dHashMicros
        ),
        incomplete: bitmap.incomplete
      )
    }

    guard let context = bitmap.cgContext else {
      return result(request, .processingFailed)
    }
    let jpegStart = DispatchTime.now()
    guard let jpeg = JpegEncoder.encode(from: context) else {
      return result(request, .processingFailed)
    }
    let jpegMicros = elapsedMicros(from: jpegStart)
    let shaStart = DispatchTime.now()
    let digest = ContentHash.sha256Hex(jpeg)
    let shaMicros = elapsedMicros(from: shaStart)
    if timedOut(from: started) {
      return result(request, .timeout).withTimings(
        CaptureTimings(
          surfaceCopyMicros: surfaceCopyMicros,
          maskFillMicros: processed.maskFillMicros,
          dHashMicros: processed.dHashMicros,
          jpegMicros: jpegMicros,
          sha256Micros: shaMicros
        )
      )
    }
    return CaptureResult(
      requestId: request.requestId,
      status: .ok,
      coverage: captureMode.coverage,
      jpeg: jpeg,
      width: bitmap.width,
      height: bitmap.height,
      dHash: processed.dHash,
      contentHash: digest,
      timings: CaptureTimings(
        surfaceCopyMicros: surfaceCopyMicros,
        maskFillMicros: processed.maskFillMicros,
        dHashMicros: processed.dHashMicros,
        jpegMicros: jpegMicros,
        sha256Micros: shaMicros
      ),
      incomplete: bitmap.incomplete
    )
  }

  private func process(bitmap: NativeBitmap, masks: [Int32], request: CaptureRequest) -> TBImageProcessResult {
    masks.withUnsafeBufferPointer { pointer in
      TBImageCoreBridge.processPixels(
        bitmap.pixels,
        width: Int32(bitmap.width),
        height: Int32(bitmap.height),
        strideBytes: Int32(bitmap.stride),
        format: tbBgra8888PixelFormat,
        masksPacked: pointer.baseAddress,
        maskIntCount: Int32(masks.count),
        lastDHash: request.lastDHash,
        force: request.force
      )
    }
  }

  private var isDisposed: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return disposed
  }

  private func isCancelled(_ requestId: Int64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cancelledId == requestId
  }

  private func isCurrent(_ requestId: Int64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return !disposed && cancelledId != requestId && inFlightId == requestId
  }

  private func setInFlight(_ requestId: Int64) {
    stateLock.lock()
    inFlightId = requestId
    stateLock.unlock()
  }

  private func clearInFlight(_ requestId: Int64) {
    stateLock.lock()
    if inFlightId == requestId {
      inFlightId = CaptureRuntime.noRequest
    }
    stateLock.unlock()
  }

  private func timedOut(from start: DispatchTime) -> Bool {
    let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    return elapsedMs >= UInt64(timeoutMs)
  }

  private func elapsedMicros(from start: DispatchTime) -> Int64 {
    Int64((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000)
  }

  private func result(_ request: CaptureRequest, _ status: CaptureStatus) -> CaptureResult {
    CaptureResult(requestId: request.requestId, status: status)
  }

  private func mapCoreStatus(_ code: Int32) -> CaptureStatus {
    switch code {
    case 0: return .ok
    case 1: return .skippedByDHash
    default: return .processingFailed
    }
  }
}

private extension AppleCaptureMode {
  var coverage: CaptureCoverage {
    switch self {
    case .engineSurface: return .engineSurface
    case .viewHierarchy: return .viewHierarchy
    }
  }
}

private extension CaptureResult {
  func withTimings(_ timings: CaptureTimings) -> CaptureResult {
    var copy = self
    copy.timings = timings
    return copy
  }
}
