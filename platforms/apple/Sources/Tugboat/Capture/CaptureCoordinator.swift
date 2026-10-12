#if canImport(UIKit)
import TugboatCaptureRuntime
import UIKit

/// Performs the engine's `capture.request` effects (stateful-engine.md 8.2).
///
/// - The request arrives on the engine queue and hops to the main thread,
///   where the key window and its size (the frame's pixel size and the
///   `surface` boundary) are read.
/// - The pixel runtime draws the whole window (`drawHierarchy`). It calls
///   `FrameMasks` on the main thread in the same turn, immediately before
///   each draw: the masks (fail closed, `WindowMasks`), the structure
///   signature, and the boundary all describe the drawn frame, never the
///   layout at the time the request arrived. It fills the masks before
///   encoding and completes on its own queue; the JPEG goes into the handle
///   table.
/// - **Every request is answered exactly once, by id (C16).** Requests may
///   overlap (the engine abandons a capture at teardown or at its C18 answer
///   deadline and may issue the next one while the host still works on the
///   earlier); each is tracked by its own runtime id and answered whenever
///   its runtime result arrives, in any order. A late answer is fine: the
///   engine ignores it and releases its frame.
final class CaptureCoordinator: CaptureRequestSink {
  /// Below the engine's 5 s C18 answer deadline, so the answer still counts.
  static let windowWaitNanos: UInt64 = 3_000_000_000
  static let windowPollSeconds: TimeInterval = 0.1

  private let mainThread: (@escaping () -> Void) -> Void
  private let mainAfter: (TimeInterval, @escaping () -> Void) -> Void
  private let window: () -> UIWindow?
  private let masks: (UIWindow) -> MaskResult
  private let capturer: WindowCapturer
  private let outcomes: RuntimeOutcomes
  private let onSurface: (CaptureGeometry) -> Void
  private let answer: (CaptureAnswer) -> Void
  private let nanoTime: () -> UInt64
  private let inFlight = Locked<[Int64: InFlightCapture]>([:])
  private let lastRuntimeId = Locked<Int64>(0)

  /// - Parameters:
  ///   - window: the window to capture (the key window), main thread.
  ///   - masks: the adapter's mask walk, main thread.
  ///   - onSurface: the window size each capture starts with, main thread,
  ///     before the capture (`SurfaceReporter`).
  ///   - answer: posts a `capture.result`; any thread.
  init(
    window: @escaping () -> UIWindow?,
    masks: @escaping (UIWindow) -> MaskResult,
    capturer: WindowCapturer,
    frames: FrameHandleTable,
    onSurface: @escaping (CaptureGeometry) -> Void,
    answer: @escaping (CaptureAnswer) -> Void,
    mainThread: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
    mainAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
      DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
    },
    nanoTime: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) {
    self.window = window
    self.masks = masks
    self.capturer = capturer
    self.outcomes = RuntimeOutcomes(frames: frames, nanoTime: nanoTime)
    self.onSurface = onSurface
    self.answer = answer
    self.mainThread = mainThread
    self.mainAfter = mainAfter
    self.nanoTime = nanoTime
  }

  /// Captures handed to the runtime and not yet answered.
  var pendingCount: Int {
    inFlight.withLock { $0.count }
  }

  /// Engine queue: returns at once.
  func onCaptureRequest(_ request: CaptureRequestEffect) {
    let received = nanoTime()
    mainThread { self.perform(request, received: received) }
  }

  /// Disposes the runtime; captures not yet drawn answer `cancelled`.
  func dispose() {
    capturer.dispose()
  }

  /// Main thread. Without a key window (the session's `initial` capture is
  /// requested before the first scene is active) it polls for one until
  /// `windowWaitNanos` after the request arrived.
  private func perform(_ request: CaptureRequestEffect, received: UInt64) {
    guard let target = window() else {
      if nanoTime() &- received < CaptureCoordinator.windowWaitNanos {
        mainAfter(CaptureCoordinator.windowPollSeconds) { self.perform(request, received: received) }
      } else {
        send(.failed(requestId: request.requestId, failure: .boundaryUnavailable, timings: nil))
      }
      return
    }
    let bounds = target.bounds
    guard
      let geometry = CaptureGeometry(
        width: Double(bounds.width), height: Double(bounds.height), screenScale: Double(target.screen.scale))
    else {
      send(.failed(requestId: request.requestId, failure: .layoutUnavailable, timings: nil))
      return
    }
    onSurface(geometry)
    start(request, on: target, geometry: geometry, received: received)
  }

  /// Registering in `inFlight` is the last step before the runtime call,
  /// and whoever removes the entry answers, so the answer is sent once.
  private func start(_ request: CaptureRequestEffect, on target: UIWindow, geometry: CaptureGeometry, received: UInt64) {
    let runtimeId = lastRuntimeId.withLock { (id: inout Int64) -> Int64 in
      id += 1
      return id
    }
    let started = nanoTime()
    let frameMasks = FrameMasks(compute: masks)
    let baseline = request.offeredBaseline
    inFlight.withLock {
      $0[runtimeId] = InFlightCapture(
        requestId: request.requestId,
        requestGeometry: geometry,
        masks: frameMasks,
        offeredBaseline: baseline,
        frameWaitMicros: Int64(clamping: (started &- received) / 1_000),
        startedNanos: started
      )
    }
    let size = geometry.pixelSize(scale: request.scale)
    let runtimeRequest = CaptureRequest(
      requestId: runtimeId,
      pixelWidth: size.width,
      pixelHeight: size.height,
      force: request.force || request.requireFreshPaint,
      lastDHash: baseline?.dHash ?? "",
      lastStructureSignature: baseline?.structureSignature ?? ""
    )
    capturer.capture(
      window: target,
      request: runtimeRequest,
      masks: { frameMasks.snapshot(for: $0) },
      onComplete: { self.onRuntimeResult($0) }
    )
  }

  /// Runtime queue (or the caller's, for an immediate result).
  private func onRuntimeResult(_ result: CaptureResult) {
    guard let capture = inFlight.withLock({ $0.removeValue(forKey: result.requestId) }) else { return }
    send(outcomes.answer(capture, result))
  }

  private func send(_ reply: CaptureAnswer) {
    answer(reply)
  }
}
#endif
