import Foundation
import TugboatSessionEngine
import XCTest

@testable import Tugboat

/// Drives `EngineHost` on a test serial queue with a fake engine and transport.
final class EngineHostTests: XCTestCase {
  private var queue: DispatchQueue!
  private var clock: FakeClock!
  private var frames: FrameHandleTable!
  private var transport: FakeEngineTransport!
  private var http: FakeHTTPSender!
  private var captures: RecordingCaptureSink!
  private var shutDowns: Locked<Int>!
  private var host: EngineHost!

  private let factAt = HostTime(monoUs: 5_000, wallUs: 7_000)
  /// `engine.dispose` stamped by the fake clock at shutdown.
  private let dispose = "{\"type\":\"engine.dispose\",\"at\":{\"monoUs\":1000000,\"wallUs\":1791712345678901},\"input\":{}}"
  private let factAtJSON = "\"at\":{\"monoUs\":5000,\"wallUs\":7000}"

  override func setUp() {
    super.setUp()
    queue = TestQueues.engine()
    clock = FakeClock()
    frames = FrameHandleTable()
    transport = FakeEngineTransport()
    http = FakeHTTPSender(frames: frames)
    captures = RecordingCaptureSink()
    let shutDowns = Locked(0)
    self.shutDowns = shutDowns
    host = EngineHost(
      transport: transport, queue: queue, http: http, frames: frames, captures: captures, clock: clock,
      onShutDown: { shutDowns.withLock { $0 += 1 } })
  }

  override func tearDown() {
    host.close()
    drain()
    super.tearDown()
  }

  /// Waits until work queued so far, and the work it queues, has run.
  private func drain(rounds: Int = 3) {
    for _ in 0..<rounds {
      queue.sync {}
    }
  }

  private func post(_ type: String, frameHandles: [String] = []) {
    host.post(type: type, inputJSON: "{}", at: factAt, frameHandles: frameHandles)
  }

  private func inMs(_ ms: Int64) -> Int64 {
    SystemHostClock().now().monoUs + ms * 1000
  }

  func testPostsAreSubmittedInOrderOnTheEngineQueue() {
    queue.suspend()
    post("a")
    host.postUntimed(type: "engine.configure", inputJSON: "{\"k\":1.0}")
    post("c")
    XCTAssertEqual(transport.submitted.count, 0, "nothing runs on the caller's thread")
    queue.resume()
    drain()

    XCTAssertEqual(
      transport.submitted,
      [
        "{\"type\":\"a\",\(factAtJSON),\"input\":{}}",
        "{\"type\":\"engine.configure\",\"input\":{\"k\":1.0}}",
        "{\"type\":\"c\",\(factAtJSON),\"input\":{}}",
      ])
    XCTAssertEqual(transport.submitsOnEngineQueue, [true, true, true])
  }

  func testPostsFromManyThreadsAreSerialized() {
    let host = self.host!
    let factAt = self.factAt
    DispatchQueue.concurrentPerform(iterations: 4) { thread in
      for index in 0..<25 {
        host.post(type: "t\(thread)", inputJSON: "{\"i\":\(index)}", at: factAt)
      }
    }
    drain()

    XCTAssertEqual(transport.submitted.count, 100)
    XCTAssertEqual(transport.overlappingSubmits, 0)
    for thread in 0..<4 {
      let order = transport.submitted
        .filter { $0.contains("\"t\(thread)\"") }
        .compactMap { (jsonObject($0)["input"] as? [String: Any])?["i"] as? Int }
      XCTAssertEqual(order, Array(0..<25), "thread \(thread) keeps its own order")
    }
  }

  func testBatchesKeepEachMessagesOwnTime() {
    host.postBatch([
      EngineMessage(type: "a", inputJSON: "{}", at: factAt),
      EngineMessage(type: "b", inputJSON: "{}", at: HostTime(monoUs: 6_000, wallUs: 8_000)),
    ])
    host.postBatch([])
    drain()

    XCTAssertEqual(
      transport.submitted,
      [
        "{\"type\":\"batch\",\"messages\":[{\"type\":\"a\",\(factAtJSON),\"input\":{}},"
          + "{\"type\":\"b\",\"at\":{\"monoUs\":6000,\"wallUs\":8000},\"input\":{}}]}"
      ])
  }

  func testEffectsRunInResponseOrder() {
    let handle = frames.put(Data([1]))
    let upload =
      "{\"type\":\"http.send\",\"requestId\":\"http-1\",\"lane\":\"frames\",\"path\":\"/v1/frames\",\"timeoutMs\":1,"
      + "\"multipart\":{\"fields\":[],\"frames\":[{\"handle\":\"\(handle)\",\"filename\":\"1.jpg\"}]}}"
    let release = "{\"type\":\"frame.release\",\"handle\":\"\(handle)\"}"
    transport.enqueue(ok(upload, release))
    transport.enqueue(ok(release, upload))

    post("first")
    post("second")
    drain()

    XCTAssertEqual(http.framesPresentAtSend, [true, false])
  }

  func testTimerEffectsScheduleReplaceCancelAndFire() {
    let flushAt = inMs(300)
    transport.enqueue(
      ok(
        "{\"type\":\"timer.schedule\",\"timerId\":\"flush\",\"atMonoUs\":\(inMs(100))}",
        "{\"type\":\"timer.schedule\",\"timerId\":\"debounce\",\"atMonoUs\":\(inMs(50))}",
        "{\"type\":\"timer.schedule\",\"timerId\":\"flush\",\"atMonoUs\":\(flushAt)}",
        "{\"type\":\"timer.cancel\",\"timerId\":\"debounce\"}"
      ))
    let fired = expectation(description: "flush fired")
    let firedAgain = expectation(description: "a second timer fired")
    firedAgain.isInverted = true
    let fires = Locked(0)
    let firedAtMonoUs = Locked<Int64>(0)
    transport.onSubmit = { message in
      guard message.contains("timer.fired") else { return }
      firedAtMonoUs.withLock { $0 = SystemHostClock().now().monoUs }
      let count = fires.withLock { (count: inout Int) -> Int in
        count += 1
        return count
      }
      if count == 1 { fired.fulfill() } else { firedAgain.fulfill() }
    }

    post("session.start")
    // A progress wait, not a speed bound: CI runners stall for seconds.
    wait(for: [fired], timeout: 30)
    wait(for: [firedAgain], timeout: 0.5)

    XCTAssertGreaterThanOrEqual(firedAtMonoUs.current, flushAt, "never fires early")
    XCTAssertEqual(
      transport.submitted.last,
      "{\"type\":\"timer.fired\",\"at\":{\"monoUs\":\(flushAt),\"wallUs\":1791712345678901},"
        + "\"input\":{\"timerId\":\"flush\"}}",
      "stamped no earlier than the deadline")
    XCTAssertEqual(transport.submitted.count, 2)
  }

  func testTransportResultsComeBackThroughTheEngineQueue() {
    transport.enqueue(
      ok(
        "{\"type\":\"http.send\",\"requestId\":\"http-42\",\"lane\":\"events\",\"path\":\"/v1/events/batch\","
          + "\"timeoutMs\":15000,\"jsonBody\":\"{\\\"a\\\":1.0}\"}"))
    post("flush")
    drain()
    XCTAssertEqual(http.requests.first?.body, .json("{\"a\":1.0}"))

    clock.set(monoUs: 2_000_000)
    queue.suspend()
    let http = self.http!
    let done = expectation(description: "completed on another thread")
    DispatchQueue.global().async {
      http.complete(0, .http(status: 202, body: "{\"sessionId\":\"s\"}"))
      done.fulfill()
    }
    // A progress wait, not a speed bound: CI runners stall for seconds.
    wait(for: [done], timeout: 30)
    XCTAssertEqual(transport.submitted.count, 1, "not submitted from the IO thread")
    queue.resume()
    drain()

    let result = jsonObject(transport.submitted.last ?? "")
    XCTAssertEqual(result["type"] as? String, "transport.result")
    XCTAssertEqual((result["at"] as? [String: Any])?["monoUs"] as? Int, 2_000_000, "stamped when the result arrived")
    let input = result["input"] as? [String: Any]
    XCTAssertEqual(input?["requestId"] as? String, "http-42")
    XCTAssertEqual(input?["status"] as? Int, 202)
    XCTAssertEqual(transport.submitsOnEngineQueue.last, true)
  }

  func testRejectedMessagesAreDroppedAndTheirFramesReleased() {
    let rejected = frames.put(Data([1]))
    let accepted = frames.put(Data([2]))
    transport.enqueue(failure(TB_SESSION_INVALID_MESSAGE))

    post("bad", frameHandles: [rejected])
    post("good", frameHandles: [accepted])
    drain()

    XCTAssertEqual(transport.submitted.count, 2)
    XCTAssertNil(frames.get(rejected), "the engine never owned it")
    XCTAssertNotNil(frames.get(accepted), "the engine owns it until frame.release")
    XCTAssertTrue(host.isRunning)
  }

  func testARejectedBatchReleasesEveryMessagesFrames() {
    let handles = (1...3).map { frames.put(Data([UInt8($0)])) }
    transport.enqueue(failure(TB_SESSION_INVALID_MESSAGE))

    host.postBatch([
      EngineMessage(type: "a", inputJSON: "{}", at: factAt, frameHandles: Array(handles.prefix(2))),
      EngineMessage(type: "b", inputJSON: "{}", at: factAt),
      EngineMessage(type: "c", inputJSON: "{}", at: factAt, frameHandles: Array(handles.suffix(1))),
    ])
    drain()

    XCTAssertEqual(frames.count, 0)
  }

  func testPostsAfterCloseReleaseTheirFrames() {
    let queued = frames.put(Data([1]))
    post("queued", frameHandles: [queued])
    host.close()
    let late = frames.put(Data([2]))
    post("late", frameHandles: [late])
    drain()

    XCTAssertEqual(transport.submitted.count, 2, "the queued post, then engine.dispose")
    XCTAssertEqual(frames.count, 0)
    XCTAssertNil(frames.get(frames.put(Data([3]))), "put after shutdown keeps nothing")
  }

  func testConsecutiveInternalErrorsDisableTheHost() {
    _ = frames.put(Data([1]))
    transport.enqueue(ok("{\"type\":\"timer.schedule\",\"timerId\":\"t\",\"atMonoUs\":\(inMs(50))}"))
    // Observe before posting, so a fire that beats the wait is still caught.
    let noTimer = expectation(description: "the timer never fires")
    noTimer.isInverted = true
    transport.onSubmit = { if $0.contains("timer.fired") { noTimer.fulfill() } }
    let limit = EngineHost.defaultMaxConsecutiveInternalErrors
    for _ in 0..<limit {
      transport.enqueue(failure(TB_SESSION_INTERNAL_ERROR))
    }

    queue.suspend()
    for index in 0...limit {
      post("m\(index)")
    }
    let queuedBeforeDisable = frames.put(Data([2]))
    post("queuedBeforeDisable", frameHandles: [queuedBeforeDisable])
    queue.resume()
    drain()
    post("afterDisable")
    wait(for: [noTimer], timeout: 0.3)
    drain()

    XCTAssertEqual(transport.submitted.count, 1 + limit + 1)
    XCTAssertEqual(transport.submitted.last, dispose, "disabling disposes the engine too")
    XCTAssertEqual(transport.submittedAtClose, transport.submitted.count)
    XCTAssertFalse(host.isRunning)
    XCTAssertTrue(transport.closed)
    XCTAssertTrue(http.closed)
    XCTAssertEqual(frames.count, 0)
    XCTAssertEqual(shutDowns.current, 1)
  }

  func testOtherStatusesResetTheInternalErrorStreak() {
    for status in [TB_SESSION_INTERNAL_ERROR, TB_SESSION_INTERNAL_ERROR, TB_SESSION_INVALID_MESSAGE, TB_SESSION_INTERNAL_ERROR, TB_SESSION_INTERNAL_ERROR] {
      transport.enqueue(failure(status))
    }
    for index in 0..<5 {
      post("m\(index)")
    }
    drain()

    XCTAssertTrue(host.isRunning)
    XCTAssertFalse(transport.closed)
  }

  func testCaptureRequestsReachTheSink() {
    transport.enqueue(ok("{\"type\":\"capture.request\",\"requestId\":\"capture-1\",\"force\":true,\"requireFreshPaint\":true}"))
    post("session.start")
    drain()

    XCTAssertEqual(captures.requests.map { $0.requestId }, ["capture-1"])
  }

  func testUnknownAndMalformedEffectsAreIgnored() {
    transport.enqueue(
      ok("{\"type\":\"capture.request\"}", "{\"type\":\"capture.request\"}", "{\"type\":\"timer.cancel\"}"))
    transport.enqueue(response(TB_SESSION_OK, "not json"))
    post("a")
    post("b")
    post("c")
    drain()

    XCTAssertEqual(transport.submitted.count, 3)
    XCTAssertTrue(host.isRunning)
  }

  func testCloseRunsQueuedWorkThenReleasesEverything() {
    _ = frames.put(Data([1]))
    transport.enqueue(ok("{\"type\":\"timer.schedule\",\"timerId\":\"t\",\"atMonoUs\":\(inMs(50))}"))
    // Observe before posting, so a fire that beats the wait is still caught.
    let noTimer = expectation(description: "the timer never fires")
    noTimer.isInverted = true
    transport.onSubmit = { if $0.contains("timer.fired") { noTimer.fulfill() } }
    post("a")
    host.close()
    post("afterClose")
    wait(for: [noTimer], timeout: 0.3)
    drain()

    XCTAssertEqual(transport.submitted, ["{\"type\":\"a\",\(factAtJSON),\"input\":{}}", dispose])
    XCTAssertEqual(transport.submittedAtClose, 2, "engine.dispose comes before the handle is destroyed")
    XCTAssertTrue(transport.closed)
    XCTAssertTrue(http.closed)
    XCTAssertEqual(frames.count, 0)
    XCTAssertEqual(shutDowns.current, 1)
    XCTAssertFalse(host.isRunning)
  }

  func testDisposeStartsNoNewWorkButReleasesFrames() {
    let released = frames.put(Data([1]))
    let kept = frames.put(Data([2]))
    post("a", frameHandles: [released, kept])
    drain()
    transport.enqueue(
      ok(
        "{\"type\":\"http.send\",\"requestId\":\"http-1\",\"lane\":\"events\",\"path\":\"/v1/events/batch\","
          + "\"timeoutMs\":1000,\"jsonBody\":\"{}\"}",
        "{\"type\":\"timer.schedule\",\"timerId\":\"t\",\"atMonoUs\":0}",
        "{\"type\":\"capture.request\",\"requestId\":\"capture-9\",\"force\":true}",
        "{\"type\":\"frame.release\",\"handle\":\"\(released)\"}"
      ))
    // The handle is destroyed before the frame table is cleared, so this
    // sees what engine.dispose's own effects did.
    let frames = self.frames!
    let atHandleClose = Locked<(released: Bool, kept: Bool)?>(nil)
    transport.onClose = {
      atHandleClose.withLock { $0 = (frames.get(released) == nil, frames.get(kept) == nil) }
    }
    let noTimer = expectation(description: "no timer starts after close")
    noTimer.isInverted = true
    transport.onSubmit = { if $0.contains("timer.fired") { noTimer.fulfill() } }

    host.close()
    wait(for: [noTimer], timeout: 0.2)
    drain()

    XCTAssertEqual(transport.submitted.last, dispose)
    XCTAssertTrue(http.requests.isEmpty, "no http.send after close")
    XCTAssertTrue(captures.requests.isEmpty, "no capture.request after close")
    XCTAssertEqual(atHandleClose.current?.released, true, "frame.release is honoured")
    XCTAssertEqual(atHandleClose.current?.kept, false)
    XCTAssertEqual(frames.count, 0)
  }

  func testAnEngineWithoutDisposeIsStillDestroyed() {
    transport.enqueue(
      response(
        TB_SESSION_UNSUPPORTED_MESSAGE,
        "{\"error\":{\"status\":\"unsupported_message\",\"message\":\"unknown message type\",\"path\":\"$.type\"}}"))
    host.close()
    drain()

    XCTAssertEqual(transport.submitted, [dispose])
    XCTAssertTrue(transport.closed)
    XCTAssertTrue(http.closed)
    XCTAssertEqual(shutDowns.current, 1)
  }
}
