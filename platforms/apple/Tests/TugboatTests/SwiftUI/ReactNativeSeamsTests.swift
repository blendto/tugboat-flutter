#if canImport(UIKit)
import UIKit
import XCTest

@_spi(TugboatAdapters) @testable import Tugboat

/// The seams the React Native adapter uses (`TugboatAdapters`): names for
/// plain UIKit views, classes that draw their own text, sensitive marks, and
/// host-named screens.
final class ReactNativeSeamsTests: XCTestCase {
  private final class Paragraph: UIView {}

  private var hosted: HostedWindow?
  private let screens = ScreenTracker.shared

  override func setUp() {
    super.setUp()
    screens.reset()
  }

  override func tearDown() {
    TugboatAdapters.setViewNameProvider(nil)
    TugboatAdapters.setViewRoleClassifier(nil)
    screens.seedsFirstScreen = false
    screens.isRecording = false
    hosted?.close()
    hosted = nil
    screens.reset()
    super.tearDown()
  }

  private func makeWindow(_ build: (UIView) -> Void) -> UIWindow {
    let controller = UIViewController()
    controller.view.backgroundColor = .white
    build(controller.view)
    let window = HostedWindow(controller: controller)
    hosted = window
    return window.window
  }

  private func box(_ parent: UIView, _ frame: CGRect, id: String? = nil, as type: UIView.Type = UIView.self) -> UIView {
    let view = type.init(frame: frame)
    view.backgroundColor = .lightGray
    view.accessibilityIdentifier = id
    parent.addSubview(view)
    return view
  }

  private func centre(_ view: UIView, in window: UIWindow) -> CGPoint {
    let frame = view.convert(view.bounds, to: window)
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  private func resolver() -> AnchorResolver {
    AnchorResolver(tags: TagRegistry(), screens: screens)
  }

  func testNamedViewsAreTargetsWithTheNameAsTagAndDistinctPaths() throws {
    TugboatAdapters.setViewNameProvider { $0.accessibilityIdentifier }
    var views: [UIView] = []
    let window = makeWindow { root in
      views.append(box(root, CGRect(x: 20, y: 100, width: 100, height: 50), id: "add"))
      views.append(box(root, CGRect(x: 20, y: 200, width: 100, height: 50), id: "remove"))
    }
    TugboatAdapters.setScreen(name: "Cart", instanceId: "cart-1")
    var anchors: [TargetAnchor] = []
    for view in views {
      guard case let .anchor(anchor) = resolver().tapEvidence(in: window, at: centre(view, in: window)) else {
        return XCTFail("a named view resolves")
      }
      anchors.append(anchor)
    }
    XCTAssertEqual(anchors.map(\.tag), ["add", "remove"])
    XCTAssertEqual(anchors.map(\.canonicalPath), ["Named#0", "Named#1"])
    XCTAssertEqual(anchors.map(\.routeKey), ["Cart", "Cart"])
    XCTAssertNotEqual(anchors[0].fingerprint, anchors[1].fingerprint)
    XCTAssertNotNil(anchors[0].tagFingerprint)
    XCTAssertFalse(anchors[0].canonicalPath.contains("add"), "the name is never in the path")
  }

  func testANamedViewCarriesTapAndEnabledUnlessItTakesNoTouches() throws {
    TugboatAdapters.setViewNameProvider { $0.accessibilityIdentifier }
    var views: [UIView] = []
    let window = makeWindow { root in
      views.append(box(root, CGRect(x: 20, y: 100, width: 100, height: 50), id: "on"))
      views.append(box(root, CGRect(x: 20, y: 200, width: 100, height: 50), id: "disabled"))
    }
    views[1].accessibilityTraits.insert(.notEnabled)
    TugboatAdapters.setScreen(name: "Cart", instanceId: "cart-1")
    var anchors: [TargetAnchor] = []
    for view in views {
      guard case let .anchor(anchor) = resolver().tapEvidence(in: window, at: centre(view, in: window)) else {
        return XCTFail("a named view resolves")
      }
      anchors.append(anchor)
    }
    XCTAssertEqual(anchors.map(\.enabled), [true, false])
    XCTAssertEqual(anchors.map(\.actions), [["tap"], []])
    // A view that takes no touches is never hit, but its state still reads as not enabled.
    views[0].isUserInteractionEnabled = false
    XCTAssertEqual(ViewKind.isEnabled(views[0]), false)
  }

  func testWithoutAProviderAPlainViewIsNoTarget() {
    let window = makeWindow { root in
      _ = box(root, CGRect(x: 20, y: 100, width: 100, height: 50), id: "add")
    }
    guard case .failed = resolver().tapEvidence(in: window, at: CGPoint(x: 60, y: 120)) else {
      return XCTFail("an unnamed plain view is not a target")
    }
  }

  func testAClassTheHostCallsTextIsMaskedWhole() {
    TugboatAdapters.setViewRoleClassifier { $0 == Paragraph.self ? .text : nil }
    var paragraph: UIView?
    var plain: UIView?
    let window = makeWindow { root in
      paragraph = box(root, CGRect(x: 20, y: 100, width: 200, height: 40), as: Paragraph.self)
      plain = box(root, CGRect(x: 20, y: 300, width: 200, height: 40))
    }
    let masks = WindowMasks.compute(window)
    XCTAssertNil(masks.fallback)
    XCTAssertEqual(masks.fractionMasked(of: hosted!.frame(of: paragraph!), in: window), 1.0)
    XCTAssertEqual(masks.fractionMasked(of: hosted!.frame(of: plain!), in: window), 0.0)
  }

  func testWithoutAClassifierTheSameClassIsNotMasked() {
    var paragraph: UIView?
    let window = makeWindow { root in
      paragraph = box(root, CGRect(x: 20, y: 100, width: 200, height: 40), as: Paragraph.self)
    }
    XCTAssertEqual(WindowMasks.compute(window).fractionMasked(of: hosted!.frame(of: paragraph!), in: window), 0.0)
  }

  func testAMarkedViewAndEverythingInItIsMaskedAndIdentityIsUnchanged() throws {
    TugboatAdapters.setViewNameProvider { $0.accessibilityIdentifier }
    var marked: UIView?
    var inner: UIView?
    var outside: UIView?
    let window = makeWindow { root in
      marked = box(root, CGRect(x: 20, y: 100, width: 300, height: 120))
      inner = box(marked!, CGRect(x: 10, y: 10, width: 100, height: 40), id: "card")
      outside = box(root, CGRect(x: 20, y: 400, width: 100, height: 40))
    }
    guard case let .anchor(before) = resolver().tapEvidence(in: window, at: centre(inner!, in: window)) else {
      return XCTFail("resolves")
    }
    TugboatAdapters.markSensitive(marked!)
    let masks = WindowMasks.compute(window)
    XCTAssertEqual(masks.stats.sensitiveViews, 1)
    XCTAssertEqual(masks.fractionMasked(of: hosted!.frame(of: marked!), in: window), 1.0)
    XCTAssertEqual(masks.fractionMasked(of: hosted!.frame(of: inner!), in: window), 1.0)
    XCTAssertEqual(masks.fractionMasked(of: hosted!.frame(of: outside!), in: window), 0.0)
    guard case let .anchor(after) = resolver().tapEvidence(in: window, at: centre(inner!, in: window)) else {
      return XCTFail("still resolves")
    }
    XCTAssertEqual(after.fingerprint, before.fingerprint)
    XCTAssertEqual(after.canonicalPath, before.canonicalPath)
  }

  func testMarkingAViewNeverUnmasksTextThatOverflowsIt() {
    TugboatAdapters.setViewRoleClassifier { $0 == Paragraph.self ? .text : nil }
    var wrapper: UIView?
    var text: UIView?
    let window = makeWindow { root in
      // A zero-height wrapper with a child below it, as React Native lays out an unclipped view.
      wrapper = box(root, CGRect(x: 20, y: 100, width: 300, height: 0))
      text = box(wrapper!, CGRect(x: 0, y: 40, width: 200, height: 40), as: Paragraph.self)
    }
    let before = WindowMasks.compute(window).fractionMasked(of: hosted!.frame(of: text!), in: window)
    TugboatAdapters.markSensitive(wrapper!)
    let after = WindowMasks.compute(window).fractionMasked(of: hosted!.frame(of: text!), in: window)
    XCTAssertEqual(before, 1.0)
    XCTAssertEqual(after, 1.0)
  }

  func testSetScreenPushesAndPopsBackToAnInstanceAlreadySeen() {
    func names() -> [String?] {
      screens.settle()
      return screens.entries(of: ScreenTracker.navigatorId)?.map(\.name) ?? []
    }
    TugboatAdapters.setScreen(name: "Home", instanceId: "home-1")
    TugboatAdapters.setScreen(name: "Cart", instanceId: "cart-1")
    XCTAssertEqual(names(), ["Home", "Cart"])
    XCTAssertEqual(screens.visibleTop?.name, "Cart")
    TugboatAdapters.setScreen(name: "Home", instanceId: "home-1")
    XCTAssertEqual(names(), ["Home"])
    TugboatAdapters.setScreen(name: "Home", instanceId: "home-1")
    XCTAssertEqual(names(), ["Home"], "the same screen again changes nothing")
  }

  func testSetScreenFromABackgroundThreadRunsOnTheMainThreadInOrder() {
    let done = expectation(description: "queued")
    DispatchQueue.global().async {
      TugboatAdapters.setScreen(name: "Home", instanceId: "home-1")
      TugboatAdapters.setScreen(name: "Cart", instanceId: "cart-1")
      DispatchQueue.main.async { done.fulfill() }
    }
    wait(for: [done], timeout: 5)
    screens.settle()
    XCTAssertEqual(screens.entries(of: ScreenTracker.navigatorId)?.map(\.name), ["Home", "Cart"])
  }

  func testAHostThatNamesScreensSeedsItsFirstScreenWithAFrameThenPushes() {
    screens.seedsFirstScreen = true
    screens.beginSession()
    screens.isRecording = true
    TugboatAdapters.setScreen(name: "Home", instanceId: "home-1")
    TugboatAdapters.setScreen(name: "Cart", instanceId: "cart-1")
    let facts = screens.takeFacts().map(\.input.json)
    XCTAssertEqual(facts.count, 2)
    XCTAssertTrue(facts[0].contains("\"kind\":\"session_start\""), facts[0])
    XCTAssertTrue(facts[0].contains("\"captureFrame\":true"), facts[0])
    XCTAssertTrue(facts[0].contains("Home"), facts[0])
    XCTAssertTrue(facts[1].contains("\"kind\":\"push\""), facts[1])
    XCTAssertFalse(facts[1].contains("captureFrame"), facts[1])
  }

  func testWithoutTheFlagTheFirstScreenIsAPush() {
    screens.beginSession()
    screens.isRecording = true
    TugboatAdapters.setScreen(name: "Home", instanceId: "home-1")
    let facts = screens.takeFacts().map(\.input.json)
    XCTAssertEqual(facts.count, 1)
    XCTAssertTrue(facts[0].contains("\"kind\":\"push\""), facts[0])
  }

  func testAScreenNamedBeforeTheSessionIsTheSeedWithoutAFrameRequest() {
    screens.seedsFirstScreen = true
    TugboatAdapters.setScreen(name: "Home", instanceId: "home-1")
    screens.beginSession()
    let facts = screens.sessionStartFacts(at: HostTime(monoUs: 0, wallUs: 0)).map(\.input.json)
    XCTAssertEqual(facts.count, 1)
    XCTAssertTrue(facts[0].contains("\"kind\":\"session_start\""), facts[0])
    // The next screen is a push: the session already has its route.
    screens.isRecording = true
    TugboatAdapters.setScreen(name: "Cart", instanceId: "cart-1")
    XCTAssertTrue(screens.takeFacts().map(\.input.json)[0].contains("\"kind\":\"push\""))
  }
}
#endif
