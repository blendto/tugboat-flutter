#if canImport(UIKit)
import UIKit
import XCTest

@testable import Tugboat

/// Scroll facts from KVO on `contentOffset`.
final class ScrollObserverTests: XCTestCase {
  private let clock = ManualClock()
  private var facts: [AdapterFact] = []
  private var frameRequests = 0
  private var anchorRequests = 0
  private var root = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
  private var scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))

  private lazy var observer = ScrollObserver(
    clock: FactClock(clock: clock),
    anchorFor: { [unowned self] _ in
      self.anchorRequests += 1
      return TargetAnchor(
        widgetType: "UIScrollView", role: "scrollable", fingerprint: "0123456789abcdef", confidence: .low,
        tagFingerprint: nil, routeKey: "Feed", tag: nil, canonicalPath: "Scrollable#0",
        relativePosition: "center", enabled: nil, actions: ["scroll"]
      )
    },
    emit: { [unowned self] in self.facts.append($0) },
    requestFrame: { [unowned self] in self.frameRequests += 1 }
  )

  override func setUp() {
    super.setUp()
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.contentSize = CGSize(width: 300, height: 2000)
    root.addSubview(scrollView)
    let textView = UITextView(frame: CGRect(x: 0, y: 420, width: 300, height: 100))
    root.addSubview(textView)
    observer.discover(in: root)
  }

  override func tearDown() {
    observer.stop()
    super.tearDown()
  }

  private var phases: [String?] {
    facts.map { $0.decodedInput["phase"] as? String }
  }

  func testDiscoveryObservesScrollViewsButNotTextViews() {
    XCTAssertEqual(observer.observedCount, 1)
    observer.discover(in: root)
    XCTAssertEqual(observer.observedCount, 1, "observed once")
  }

  func testAMoveSendsStartWithTheAnchorThenUpdateThenEndWhenIdle() throws {
    let movedAt = clock.now()
    scrollView.contentOffset = CGPoint(x: 0, y: 120)
    XCTAssertEqual(frameRequests, 1)
    clock.advance(ms: 16)
    observer.onFrame()

    XCTAssertEqual(phases, ["start", "update"])
    let start = facts[0].decodedInput
    XCTAssertEqual(start["offset"] as? Double, 0, "start is at the resting offset")
    XCTAssertEqual(start["axis"] as? String, "vertical")
    XCTAssertEqual(start["maxScrollExtent"] as? Double, 1600)
    XCTAssertEqual((start["anchor"] as? [String: Any])?["toolkit"] as? String, "swiftui")
    XCTAssertEqual(facts[1].decodedInput["offset"] as? Double, 120)
    XCTAssertNil(facts[1].decodedInput["anchor"], "anchor on start only")
    XCTAssertEqual(facts[1].at, movedAt, "the time of the change, not of the frame")
    let id = try XCTUnwrap(start["scrollableId"] as? String)
    XCTAssertEqual(id, ScrollViewReading.id(of: scrollView))

    clock.advance(ms: 50)
    observer.onFrame()
    XCTAssertEqual(phases.count, 2, "not idle long enough")
    clock.advance(ms: 100)
    observer.onFrame()
    XCTAssertEqual(phases, ["start", "update", "end"])
    XCTAssertEqual(facts[2].decodedInput["scrollableId"] as? String, id, "stable id")
    XCTAssertEqual(anchorRequests, 1)
  }

  func testAFingerDrivenMoveSendsStartAtOnceBeforeTheFrame() throws {
    let dragged = TrackedScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    dragged.contentInsetAdjustmentBehavior = .never
    dragged.contentSize = CGSize(width: 300, height: 2000)
    root.addSubview(dragged)
    observer.discover(in: root)
    dragged.tracking = true

    dragged.contentOffset = CGPoint(x: 0, y: 40)
    XCTAssertEqual(phases, ["start"], "sent from the KVO callback, before the pointer's up is batched")
    dragged.contentOffset = CGPoint(x: 0, y: 80)
    observer.onFrame()
    XCTAssertEqual(phases, ["start", "update"], "one start per scroll")
    XCTAssertEqual(facts[1].decodedInput["offset"] as? Double, 80)
  }

  func testScrollViewsUnderAPointerDownAreObservedAtOnce() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
    window.isHidden = false
    defer { window.isHidden = true }
    let pushed = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
    let content = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
    pushed.addSubview(content)
    window.addSubview(pushed)
    let before = observer.observedCount
    observer.observe(at: CGPoint(x: 50, y: 50), in: window)
    XCTAssertEqual(observer.observedCount, before + 1)
  }

  func testRubberBandingSendsOneOverscroll() {
    scrollView.contentOffset = CGPoint(x: 0, y: -30)
    observer.onFrame()
    scrollView.contentOffset = CGPoint(x: 0, y: -40)
    observer.onFrame()
    XCTAssertEqual(phases, ["start", "update", "overscroll", "update"])
    let overscroll = facts[2].decodedInput
    XCTAssertEqual(Set(overscroll.keys), ["scrollableId", "phase"], "overscroll carries only the id")
  }

  func testAnInsetChangeAloneIsNotAScroll() {
    scrollView.contentInset = UIEdgeInsets(top: 50, left: 0, bottom: 0, right: 0)
    scrollView.contentOffset = CGPoint(x: 0, y: -50)
    observer.onFrame()
    XCTAssertTrue(facts.isEmpty)
  }

  func testHorizontalScrollsReportTheHorizontalAxis() {
    let carousel = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
    carousel.contentInsetAdjustmentBehavior = .never
    carousel.contentSize = CGSize(width: 1200, height: 100)
    root.addSubview(carousel)
    observer.discover(in: root)
    carousel.contentOffset = CGPoint(x: 90, y: 0)
    observer.onFrame()
    XCTAssertEqual(facts.last?.decodedInput["axis"] as? String, "horizontal")
    XCTAssertEqual(facts.last?.decodedInput["offset"] as? Double, 90)
    XCTAssertEqual(facts.last?.decodedInput["maxScrollExtent"] as? Double, 900)
  }

  func testStopEndsActiveScrolls() {
    scrollView.contentOffset = CGPoint(x: 0, y: 10)
    observer.onFrame()
    observer.stop()
    XCTAssertEqual(phases, ["start", "update", "end"])
    scrollView.contentOffset = CGPoint(x: 0, y: 30)
    observer.onFrame()
    XCTAssertEqual(phases.count, 3, "no longer observed")
  }
}
#endif

#if canImport(UIKit)
/// A scroll view a test can mark as finger-driven.
final class TrackedScrollView: UIScrollView {
  var tracking = false

  override var isTracking: Bool {
    tracking
  }
}
#endif
