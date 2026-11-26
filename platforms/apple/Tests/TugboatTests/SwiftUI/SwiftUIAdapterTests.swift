#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// The adapter end to end, with a recording sink and manual frames.
final class SwiftUIAdapterTests: XCTestCase {
  private var hosted: HostedWindow?
  private let sink = RecordingSink()
  private let frames = ManualFrames()
  private let center = NotificationCenter()
  private let screens = ScreenTracker(clock: ManualClock())
  private var adapter: SwiftUIAdapter?

  override func tearDown() {
    adapter?.stop()
    adapter = nil
    hosted?.close()
    hosted = nil
    HostingControllerTracker.shared.reset()
    super.tearDown()
  }

  private func start() -> SwiftUIAdapter {
    let adapter = SwiftUIAdapter(
      sink: sink, hostClock: ManualClock(), frames: frames, trackHostingControllers: false,
      screens: screens, tags: TagRegistry(), center: center
    )
    adapter.start()
    self.adapter = adapter
    return adapter
  }

  private func recognizers(_ window: UIWindow) -> [WindowPointerRecognizer] {
    (window.gestureRecognizers ?? []).compactMap { $0 as? WindowPointerRecognizer }
  }

  func testTheRecognizerNeverInterferesWithTheApp() throws {
    let recognizer = WindowPointerRecognizer(onSample: { _ in }, onReset: {})
    XCTAssertFalse(recognizer.cancelsTouchesInView)
    XCTAssertFalse(recognizer.delaysTouchesBegan)
    XCTAssertFalse(recognizer.delaysTouchesEnded)
    let other = UIPanGestureRecognizer()
    XCTAssertFalse(recognizer.canPrevent(other))
    XCTAssertFalse(recognizer.canBePrevented(by: other))
    XCTAssertFalse(recognizer.shouldRequireFailure(of: other))
    XCTAssertFalse(recognizer.shouldBeRequiredToFail(by: other))
    let delegate = try XCTUnwrap(recognizer.delegate)
    XCTAssertEqual(delegate.gestureRecognizer?(recognizer, shouldRecognizeSimultaneouslyWith: other), true)
  }

  func testAttachesOnceToEachWindowThatBecomesKeyAndDetachesOnStop() {
    _ = start()
    let window = HostedWindow(Text("Hello"))
    hosted = window
    center.post(name: UIWindow.didBecomeKeyNotification, object: window.window)
    center.post(name: UIWindow.didBecomeKeyNotification, object: window.window)
    XCTAssertEqual(recognizers(window.window).count, 1)

    adapter?.stop()
    XCTAssertTrue(recognizers(window.window).isEmpty)
  }

  func testScreenFactsLeaveInTheNextFrameBatch() throws {
    _ = start()
    let window = HostedWindow(Text("Home").modifier(TugboatScreenModifier(name: "Home", tracker: screens)))
    hosted = window
    XCTAssertTrue(window.wait { self.frames.pending > 0 })
    frames.runFrame()

    let navigation = sink.decoded.filter { $0["type"] as? String == "navigation" }
    XCTAssertEqual(navigation.count, 1)
    let input = try XCTUnwrap(navigation.first?["input"] as? [String: Any])
    XCTAssertEqual((input["route"] as? [String: Any])?["name"] as? String, "Home")
    XCTAssertNotNil(navigation.first?["at"])
  }

  func testStopFlushesAndStopsRecording() {
    _ = start()
    screens.appeared(instanceId: "s", name: "Late")
    adapter?.stop()
    XCTAssertEqual(sink.decoded.filter { $0["type"] as? String == "navigation" }.count, 1)
    XCTAssertTrue(frames.invalidated)
    screens.appeared(instanceId: "t", name: "After")
    XCTAssertTrue(screens.takeFacts().isEmpty)
  }

  func testMasksForAWindowDelegateToTheMaskWalk() {
    let adapter = start()
    let window = HostedWindow(Text("Masked"))
    hosted = window
    let settled = window.settledMasks()
    XCTAssertEqual(adapter.masks(for: window.window).fallback, settled.fallback)
    XCTAssertEqual(adapter.masks(for: window.window).rects, settled.rects)
  }
}
#endif
