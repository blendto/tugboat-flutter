import Foundation
import XCTest

@testable import Tugboat

final class EffectDispatcherTests: XCTestCase {
  private let queue = TestQueues.engine()
  private let frames = FrameHandleTable()
  private let http = FakeHTTPSender()
  private let logs = Locked<[String]>([])
  private let posts = Locked<[String]>([])

  private func makeDispatcher(
    captures: CaptureRequestSink? = nil,
    onFired: @escaping (String, Int64) -> Void = { _, _ in }
  ) -> EffectDispatcher {
    let logs = self.logs
    let posts = self.posts
    return EffectDispatcher(
      timers: TimerExecutor(queue: queue, onFired: onFired),
      http: http,
      frames: frames,
      captures: captures,
      post: { type, input in posts.withLock { $0.append(type + " " + input) } },
      log: { message in logs.withLock { $0.append(message) } })
  }

  func testUnknownTypesAreLoggedOncePerType() {
    let dispatcher = makeDispatcher()
    queue.sync {
      for effect in [Effect.unknown(type: "screen.wake"), .unknown(type: "screen.wake"), .unknown(type: "a"), .unknown(type: "a"), .unknown(type: "b")] {
        dispatcher.dispatch(effect)
      }
    }
    XCTAssertEqual(logs.current.count, 3)
  }

  func testCaptureRequestsGoToTheSinkInOrder() {
    let sink = RecordingCaptureSink()
    let dispatcher = makeDispatcher(captures: sink)
    let first = CaptureRequestEffect(requestId: "capture-1", force: true, requireFreshPaint: true, scale: 1, dHashBaseline: nil)
    let second = CaptureRequestEffect(requestId: "capture-2", force: false, requireFreshPaint: false, scale: 0.8, dHashBaseline: nil)
    queue.sync {
      dispatcher.dispatch(.captureRequest(first))
      dispatcher.dispatch(.captureRequest(second))
    }
    XCTAssertEqual(sink.requests, [first, second])
    XCTAssertTrue(logs.current.isEmpty)
  }

  func testCaptureRequestsWithoutASinkAreLoggedOnce() {
    let dispatcher = makeDispatcher()
    let request = CaptureRequestEffect(requestId: "capture-1", force: true, requireFreshPaint: true, scale: 1, dHashBaseline: nil)
    queue.sync {
      dispatcher.dispatch(.captureRequest(request))
      dispatcher.dispatch(.captureRequest(request))
    }
    XCTAssertEqual(logs.current.count, 1)
  }

  func testFrameReleaseFreesTheHandle() {
    let dispatcher = makeDispatcher()
    let handle = frames.put(Data([1]))
    queue.sync { dispatcher.dispatch(.frameRelease(handle: handle)) }
    XCTAssertNil(frames.get(handle))
  }

  func testHTTPResultsArePostedAsTransportResults() {
    let dispatcher = makeDispatcher()
    let request = HTTPRequest(requestId: "http-9", lane: "events", path: "/v1/events/batch", timeoutMs: 1, body: .json("{}"))
    queue.sync { dispatcher.dispatch(.httpSend(request)) }
    XCTAssertEqual(http.requests, [request])

    http.complete(0, .timeout)
    XCTAssertEqual(posts.current, ["transport.result {\"requestId\":\"http-9\",\"outcome\":\"timeout\"}"])
  }

  func testTimersAreScheduledAndCancelled() {
    let fired = expectation(description: "kept timer fired")
    let dispatcher = makeDispatcher { timerId, _ in
      XCTAssertEqual(timerId, "keep")
      fired.fulfill()
    }
    let soon = SystemHostClock().now().monoUs + 20_000
    queue.sync {
      dispatcher.dispatch(.timerSchedule(timerId: "drop", atMonoUs: soon))
      dispatcher.dispatch(.timerSchedule(timerId: "keep", atMonoUs: soon))
      dispatcher.dispatch(.timerCancel(timerId: "drop"))
    }
    wait(for: [fired], timeout: 2)
    queue.sync {}
  }
}

final class RecordingCaptureSink: CaptureRequestSink {
  private let received = Locked<[CaptureRequestEffect]>([])

  var requests: [CaptureRequestEffect] { received.current }

  func onCaptureRequest(_ request: CaptureRequestEffect) {
    received.withLock { $0.append(request) }
  }
}
