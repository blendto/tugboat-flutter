#if canImport(UIKit)
import TugboatCaptureRuntime
import UIKit

/// Performs the engine's `capture.request` effects (stateful-engine.md 8.2).
///
/// - The request arrives on the engine queue and hops to the main thread,
///   where the key window is looked up. Nothing about its size is read
///   there.
/// - The pixel runtime draws the whole window (`drawHierarchy`). It calls
///   `FrameMasks` on the main thread in the same turn, after layout and
///   immediately before each draw. That one reading of the window gives the
///   masks (fail closed, `WindowMasks`), the structure signature, the
///   boundary (posted as `surface` when it changed, before the
///   `capture.result`), and the pixel size (`pixelsPerPoint`). It fills the
///   masks before encoding and completes on its own queue; the JPEG goes
///   into the handle table.
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
  private let makeMasks: () -> FrameMasks
  private let capturer: WindowCapturer
  private let outcomes: RuntimeOutcomes
  private let answer: (CaptureAnswer) -> Void
  private let nanoTime: () -> UInt64
  private let inFlight = Locked<[Int64: InFlightCapture]>([:])
  private let lastRuntimeId = Locked<Int64>(0)

  /// - Parameters:
  ///   - window: the window to capture (the key window), main thread.
  ///   - masks: a new supplier per capture (`FrameMasks`).
  ///   - answer: posts a `capture.result`; any thread.
  init(
    window: @escaping () -> UIWindow?,
    masks: @escaping () -> FrameMasks,
    capturer: WindowCapturer,
    frames: FrameHandleTable,
    answer: @escaping (CaptureAnswer) -> Void,
    mainThread: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
    mainAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
      DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
    },
    nanoTime: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) {
    self.window = window
    self.makeMasks = masks
    self.capturer = capturer
    self.outcomes = RuntimeOutcomes(frames: frames, nanoTime: nanoTime)
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
        answer(.failed(requestId: request.requestId, failure: .boundaryUnavailable, timings: nil))
      }
      return
    }
    start(request, on: target, received: received)
  }

  /// Registering in `inFlight` is the last step before the runtime call,
  /// and whoever removes the entry answers, so the answer is sent once.
  private func start(_ request: CaptureRequestEffect, on target: UIWindow, received: UInt64) {
    let runtimeId = lastRuntimeId.withLock { (id: inout Int64) -> Int64 in
      id += 1
      return id
    }
    let started = nanoTime()
    let frameMasks = makeMasks()
    let baseline = request.offeredBaseline
    inFlight.withLock {
      $0[runtimeId] = InFlightCapture(
        requestId: request.requestId,
        masks: frameMasks,
        offeredBaseline: baseline,
        frameWaitMicros: Int64(clamping: (started &- received) / 1_000),
        startedNanos: started
      )
    }
    // The size follows the window at draw time; the fixed size is unused.
    let runtimeRequest = CaptureRequest(
      requestId: runtimeId,
      pixelWidth: 1,
      pixelHeight: 1,
      force: request.force || request.requireFreshPaint,
      lastDHash: baseline?.dHash ?? "",
      lastStructureSignature: baseline?.structureSignature ?? "",
      pixelsPerPoint: CaptureGeometry.pixelsPerPoint(scale: request.scale)
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
    answer(outcomes.answer(capture, result))
  }
}
#endif
