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
}
#endif
