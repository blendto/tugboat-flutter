#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// Tagged SwiftUI targets drawn in one hosting view get distinct structural
/// paths (`Tagged#<layout ordinal>`, never the tag value); UIKit controls,
/// including the navigation bar's back button, resolve to `button` anchors.
final class TaggedAndControlIdentityTests: XCTestCase {
  private var hosted: HostedWindow?
  private let registry = TagRegistry()
  private let screens = ScreenTracker(clock: ManualClock())

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private var resolver: AnchorResolver {
    AnchorResolver(tags: registry, screens: screens)
  }

  private func marker(_ tag: String) -> TagMarkerView? {
    registry.all.first { $0.tugboatTag == tag && $0.window != nil }
  }

  private func centre(of view: UIView, in window: UIWindow) -> CGPoint {
    let frame = view.convert(view.bounds, to: window)
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  func testTaggedButtonsInOneHostingViewHaveDistinctPathsInLayoutOrder() throws {
    let window = HostedWindow(
      VStack(spacing: 40) {
        Button("Stop") {}.modifier(TugboatTagModifier(tag: "stop", registry: registry))
        HStack(spacing: 40) {
          Button("Add") {}.modifier(TugboatTagModifier(tag: "add", registry: registry))
          Button("Open") {}.modifier(TugboatTagModifier(tag: "open", registry: registry))
        }
      }
      .modifier(TugboatScreenModifier(name: "Home", tracker: screens))
    )
    hosted = window
    XCTAssertTrue(window.wait { ["stop", "add", "open"].allSatisfy { self.marker($0) != nil } })
    window.settle()

    var paths: [String: String] = [:]
    var fingerprints: Set<String> = []
    for tag in ["stop", "add", "open"] {
      let point = centre(of: try XCTUnwrap(marker(tag)), in: window.window)
      guard case let .anchor(anchor) = resolver.tapEvidence(in: window.window, at: point) else {
        return XCTFail("\(tag) resolves")
      }
      XCTAssertEqual(anchor.tag, tag)
      XCTAssertFalse(anchor.canonicalPath.contains(tag), "the tag value is never in the path")
      XCTAssertEqual(anchor.confidence, .high)
      paths[tag] = anchor.canonicalPath
      fingerprints.insert(anchor.fingerprint)
    }
    XCTAssertEqual(paths["stop"], "Tagged#0", "top first")
    XCTAssertEqual(paths["add"], "Tagged#1", "then leading to trailing")
    XCTAssertEqual(paths["open"], "Tagged#2")
    XCTAssertEqual(fingerprints.count, 3, "distinct structural fingerprints")
  }

  func testAUIKitButtonIsAButtonAnchor() throws {
    let controller = UIViewController()
    let button = UIButton(type: .system)
    button.setTitle("Pay", for: .normal)
    button.frame = CGRect(x: 40, y: 200, width: 120, height: 44)
    controller.view.addSubview(button)
    let window = HostedWindow(controller: controller)
    hosted = window

    guard case let .anchor(anchor) = resolver.tapEvidence(in: window.window, at: CGPoint(x: 100, y: 222)) else {
      return XCTFail("the button resolves")
    }
    XCTAssertEqual(anchor.role, "button")
    XCTAssertEqual(anchor.widgetType, "UIButton")
    XCTAssertEqual(anchor.actions, ["tap"])
    XCTAssertTrue(anchor.canonicalPath.hasSuffix("Control#0"), anchor.canonicalPath)
    XCTAssertEqual(anchor.confidence, .low)
  }

  func testTheNavigationBarBackButtonIsAButtonAnchor() throws {
    let root = UIViewController()
    root.title = "Home"
    let navigation = UINavigationController(rootViewController: root)
    let window = HostedWindow(controller: navigation)
    hosted = window
    let details = UIViewController()
    details.title = "Details"
    navigation.pushViewController(details, animated: false)
    window.settle(0.5)

    let bar = navigation.navigationBar
    let candidates = window.views(UIControl.self).filter {
      $0.isDescendant(of: bar) && $0.bounds.width > 0 && !$0.isHidden && $0.alpha > 0.01
    }
    print("TBDUMP back-button candidates: \(candidates.map { String(describing: type(of: $0)) })")
    let back = try XCTUnwrap(
      candidates.min { $0.convert($0.bounds, to: window.window).minX < $1.convert($1.bounds, to: window.window).minX },
      "a UIKit control in the navigation bar")
    guard case let .anchor(anchor) = resolver.tapEvidence(in: window.window, at: centre(of: back, in: window.window)) else {
      return XCTFail("the back button resolves to an anchor")
    }
    XCTAssertEqual(anchor.role, "button", "\(anchor)")
    XCTAssertTrue(anchor.canonicalPath.contains("Control#"), anchor.canonicalPath)
    XCTAssertNotEqual(anchor.confidence, .high)
  }
}
#endif
