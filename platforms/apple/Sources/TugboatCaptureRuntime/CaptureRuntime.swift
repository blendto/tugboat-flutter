import Foundation
import UIKit
#if SWIFT_PACKAGE
import TugboatImageCoreBridge
#endif

public final class CaptureRuntime {
  public static let minNativeApi: Int = 15
  public static let defaultTimeoutMs: Int64 = 2_000
  public static let jpegQuality: Int = 80

  private static let noRequest: Int64 = -1

  private let timeoutMs: Int64
  private let coverage: CaptureCoverage
  private let queue = DispatchQueue(label: "tugboat-capture")
  private let lock = NSLock()
  private var session = Session()

  public init(
    timeoutMs: Int64 = CaptureRuntime.defaultTimeoutMs,
    coverage: CaptureCoverage = .engineSurface
  ) {
    self.timeoutMs = timeoutMs
    self.coverage = coverage
  }

  public func capabilities() -> CaptureCapabilities {
    let api = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return CaptureCapabilities(
      nativeCaptureSupported: api >= CaptureRuntime.minNativeApi,
      apiLevel: api
    )
  }

  public func capture(view: UIView, request: CaptureRequest, onComplete: @escaping (CaptureResult) -> Void) {
    if isDisposed {
      onComplete(reply(request, .disposed))
      return
    }
    queue.async { [weak self] in
      guard let self else {
        onComplete(CaptureResult(requestId: request.requestId, status: .disposed))
        return
      }
      self.setInFlight(request.requestId)
      let outcome = self.captureSync(view: view, request: request)
      self.clearInFlight(request.requestId)
      onComplete(outcome)
    }
  }

  public func cancel(requestId: Int64) {
    withSession { $0.cancelledId = requestId }
  }

  public func dispose() {
    withSession { $0.disposed = true }
  }

  private func captureSync(view: UIView, request: CaptureRequest) -> CaptureResult {
    if isDisposed { return reply(request, .disposed) }
    if isCancelled(request.requestId) { return reply(request, .cancelled) }
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < CaptureRuntime.minNativeApi {
      return reply(request, .unsupportedApi)
    }
    if request.pixelWidth <= 0 || request.pixelHeight <= 0 {
      return reply(request, .processingFailed)
    }
    if request.pixelWidth > Self.maxEdge || request.pixelHeight > Self.maxEdge
      || request.pixelWidth > Self.maxPixels / request.pixelHeight
    {
      return reply(request, .processingFailed)
    }

    let started = DispatchTime.now()
    let drawOutcome = drawOnMain(view: view, request: request)
    let copyTimings = CaptureTimings(surfaceCopyMicros: elapsedMicros(from: started))
    if let early = haltIfNeeded(request, started, copyTimings) {
      return early
    }
    guard let bitmap = drawOutcome.bitmap else {
      let status: CaptureStatus = drawOutcome.hasSurface ? .pixelCopyFailed : .surfaceUnavailable
      return reply(request, status, timings: copyTimings)
    }

    let processed = process(bitmap: bitmap, request: request)
    let coreTimings = CaptureTimings(
      surfaceCopyMicros: copyTimings.surfaceCopyMicros,
      maskFillMicros: processed.maskFillMicros,
      dHashMicros: processed.dHashMicros
    )
    if let early = haltIfNeeded(request, started, coreTimings) {
      return early
    }
    let coreStatus = mapCoreStatus(processed.status)
    if coreStatus != .ok && coreStatus != .skippedByDHash {
      return reply(request, coreStatus)
    }
    if coreStatus == .skippedByDHash {
      return reply(
        request,
        .skippedByDHash,
        coverage: bitmap.coverage,
        width: bitmap.width,
        height: bitmap.height,
        dHash: processed.dHash,
        timings: coreTimings,
        incomplete: bitmap.incomplete
      )
    }

    let jpegStart = DispatchTime.now()
    guard let jpeg = bitmap.jpegData() else {
      return reply(request, .processingFailed)
    }
    let jpegMicros = elapsedMicros(from: jpegStart)
    let shaStart = DispatchTime.now()
    let digest = ContentHash.sha256Hex(jpeg)
    let encodedTimings = CaptureTimings(
      surfaceCopyMicros: coreTimings.surfaceCopyMicros,
      maskFillMicros: coreTimings.maskFillMicros,
      dHashMicros: coreTimings.dHashMicros,
      jpegMicros: jpegMicros,
      sha256Micros: elapsedMicros(from: shaStart)
    )
    if let early = haltIfNeeded(request, started, encodedTimings) {
      return early
    }
    return reply(
      request,
      .ok,
      coverage: bitmap.coverage,
      jpeg: jpeg,
      width: bitmap.width,
      height: bitmap.height,
      dHash: processed.dHash,
      contentHash: digest,
      timings: encodedTimings,
      incomplete: bitmap.incomplete
    )
  }

  private func drawOnMain(
    view: UIView,
    request: CaptureRequest
  ) -> (bitmap: NativeBitmap?, hasSurface: Bool) {
    var bitmap: NativeBitmap?
    var hasSurface = false
    let draw = {
      view.layoutIfNeeded()
      hasSurface = view.bounds.width > 0 && view.bounds.height > 0
      guard hasSurface else { return }
      bitmap = AppleViewCapture.capture(
        view: view,
        pixelWidth: request.pixelWidth,
        pixelHeight: request.pixelHeight,
        coverage: self.coverage
      )
    }
    if Thread.isMainThread {
      draw()
    } else {
      DispatchQueue.main.sync(execute: draw)
    }
    return (bitmap, hasSurface)
  }

  private func haltIfNeeded(
    _ request: CaptureRequest,
    _ started: DispatchTime,
    _ timings: CaptureTimings
  ) -> CaptureResult? {
    if !isCurrent(request.requestId) {
      return reply(request, .cancelled)
    }
    if timedOut(from: started) {
      return reply(request, .timeout, timings: timings)
    }
    return nil
  }

  private func process(bitmap: NativeBitmap, request: CaptureRequest) -> TBImageProcessResult {
    let masks = MaskMapper.toPixelRects(
      masks: request.masks,
      width: bitmap.width,
      height: bitmap.height
    )
    return masks.withUnsafeBufferPointer { pointer in
      TBImageCoreBridge.processPixels(
        bitmap.pixels,
        width: Int32(bitmap.width),
        height: Int32(bitmap.height),
        strideBytes: Int32(bitmap.stride),
        format: TBImageCorePixelFormatBGRA8888,
        masksPacked: pointer.baseAddress,
        maskIntCount: Int32(masks.count),
        lastDHash: request.lastDHash,
        force: request.force
      )
    }
  }

  private func reply(
    _ request: CaptureRequest,
    _ status: CaptureStatus,
    coverage: CaptureCoverage? = nil,
    jpeg: Data = Data(),
    width: Int = 0,
    height: Int = 0,
    dHash: String = "",
    contentHash: String = "",
    timings: CaptureTimings = CaptureTimings(),
    incomplete: Bool = false
  ) -> CaptureResult {
    CaptureResult(
      requestId: request.requestId,
      status: status,
      coverage: coverage,
      jpeg: jpeg,
      width: width,
      height: height,
      dHash: dHash,
      contentHash: contentHash,
      timings: timings,
      incomplete: incomplete
    )
  }

  private var isDisposed: Bool {
    withSession { $0.disposed }
  }

  private func isCancelled(_ requestId: Int64) -> Bool {
    withSession { $0.cancelledId == requestId }
  }

  private func isCurrent(_ requestId: Int64) -> Bool {
    withSession { session in
      !session.disposed && session.cancelledId != requestId && session.inFlightId == requestId
    }
  }

  private func setInFlight(_ requestId: Int64) {
    withSession { $0.inFlightId = requestId }
  }

  private func clearInFlight(_ requestId: Int64) {
    withSession { session in
      if session.inFlightId == requestId {
        session.inFlightId = CaptureRuntime.noRequest
      }
    }
  }

  private func timedOut(from start: DispatchTime) -> Bool {
    let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    return elapsedMs >= UInt64(timeoutMs)
  }

  private func elapsedMicros(from start: DispatchTime) -> Int64 {
    Int64((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000)
  }

  private func mapCoreStatus(_ code: Int32) -> CaptureStatus {
    switch code {
    case 0: return .ok
    case 1: return .skippedByDHash
    default: return .processingFailed
    }
  }

  @discardableResult
  private func withSession<T>(_ body: (inout Session) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&session)
  }

  private struct Session {
    var disposed = false
    var inFlightId: Int64 = CaptureRuntime.noRequest
    var cancelledId: Int64 = CaptureRuntime.noRequest
  }

  private static let maxEdge = 8192
  private static let maxPixels = 16_777_216
}
