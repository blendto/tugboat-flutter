#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// Identity on hosted SwiftUI views (native SDK note 6.3) without tags:
/// UIKit hit-testing for text fields, list cells, and scroll views.
final class SwiftUIIdentityTests: XCTestCase {
  private var hosted: HostedWindow?
  private let registry = TagRegistry()
  private let screens = ScreenTracker(clock: ManualClock())

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private func host<Content: View>(_ content: Content) -> HostedWindow {
    let window = HostedWindow(content)
    hosted = window
    return window
  }

  private func anchor(_ evidence: TapEvidence, file: StaticString = #filePath, line: UInt = #line) -> TargetAnchor? {
    guard case let .anchor(anchor) = evidence else {
      XCTFail("expected an anchor, got \(evidence)", file: file, line: line)
      return nil
    }
    return anchor
  }

  /// Applies queued screen callbacks, then reports whether a screen is up.
  private var screenOnTop: Bool {
    screens.settle()
    return screens.visibleTop != nil
  }

  private var resolver: AnchorResolver {
    AnchorResolver(tags: registry, screens: screens)
  }

  func testAListRowResolvesToItsCellIndexPath() throws {
    let window = host(
      List(0..<30, id: \.self) { index in
        Text("Row \(index)")
      }
      .modifier(TugboatScreenModifier(name: "Inbox", tracker: screens))
    )
    XCTAssertTrue(window.wait { self.screenOnTop && !self.cells(in: window).isEmpty })
    let rows = cells(in: window).sorted { window.frame(of: $0).minY < window.frame(of: $1).minY }
    let third = try XCTUnwrap(rows.dropFirst(2).first)
    let expected = try XCTUnwrap(CanonicalPathBuilder.itemIndexPath(of: third))
    let centre = CGPoint(x: window.frame(of: third).midX, y: window.frame(of: third).midY)

    let resolved = try XCTUnwrap(anchor(resolver.tapEvidence(in: window.window, at: centre)))
    XCTAssertTrue(resolved.canonicalPath.contains("[item:\(expected.section).\(expected.row)]"), resolved.canonicalPath)
    XCTAssertTrue(resolved.canonicalPath.hasSuffix("Cell#0"), resolved.canonicalPath)
    XCTAssertTrue(resolved.canonicalPath.contains("Scrollable#0"), resolved.canonicalPath)
    XCTAssertEqual(resolved.confidence, .medium, "an index path without a tag")
    XCTAssertEqual(resolved.routeKey, "Inbox")
    XCTAssertEqual(resolved.actions, ["tap"])
    XCTAssertTrue(["UICollectionViewCell", "UITableViewCell"].contains(resolved.widgetType))
  }

  func testATextFieldResolvesToTheTextFieldRole() throws {
    let window = host(
      VStack {
        TextField("Email", text: .constant(""))
          .textFieldStyle(.roundedBorder)
          .padding()
        Spacer()
      }
      .modifier(TugboatScreenModifier(name: "Login", tracker: screens))
    )
    XCTAssertTrue(window.wait { !window.views(UITextField.self).isEmpty })
    let field = try XCTUnwrap(window.views(UITextField.self).first)
    let frame = window.frame(of: field)

    let resolved = try XCTUnwrap(anchor(resolver.tapEvidence(in: window.window, at: CGPoint(x: frame.midX, y: frame.midY))))
    XCTAssertEqual(resolved.role, "textField")
    XCTAssertEqual(resolved.widgetType, "UITextField")
    XCTAssertTrue(resolved.canonicalPath.hasSuffix("TextField#0"), resolved.canonicalPath)
    XCTAssertEqual(resolved.confidence, .low, "no tag and no index path")
    XCTAssertEqual(resolved.enabled, true)
    XCTAssertEqual(resolved.actions, ["input", "tap"])
    XCTAssertEqual(resolved.relativePosition, "top")
  }

  func testAScrollViewResolvesToTheScrollableRole() throws {
    let window = host(
      ScrollView {
        VStack {
          ForEach(0..<60, id: \.self) { Text("Item \($0)").frame(height: 30) }
        }
      }
      .modifier(TugboatScreenModifier(name: "Feed", tracker: screens))
    )
    XCTAssertTrue(window.wait { !window.views(UIScrollView.self).isEmpty })
    let scrollView = try XCTUnwrap(window.views(UIScrollView.self).first)
    let frame = window.frame(of: scrollView)

    let resolved = try XCTUnwrap(anchor(resolver.tapEvidence(in: window.window, at: CGPoint(x: frame.midX, y: frame.midY))))
    XCTAssertEqual(resolved.role, "scrollable")
    XCTAssertEqual(resolved.canonicalPath, "Scrollable#0")
    XCTAssertEqual(resolved.actions, ["scroll"])
    XCTAssertEqual(resolver.anchor(for: scrollView, in: window.window), resolved, "scroll anchors resolve the same way")
  }

  func testIdentityIsStableAcrossResolutions() throws {
    let window = host(TextField("Name", text: .constant("")).padding().modifier(TugboatScreenModifier(name: "Profile", tracker: screens)))
    XCTAssertTrue(window.wait { !window.views(UITextField.self).isEmpty })
    let field = try XCTUnwrap(window.views(UITextField.self).first)
    let point = CGPoint(x: window.frame(of: field).midX, y: window.frame(of: field).midY)
    let first = try XCTUnwrap(anchor(resolver.tapEvidence(in: window.window, at: point)))
    window.settle()
    let second = try XCTUnwrap(anchor(resolver.tapEvidence(in: window.window, at: point)))
    XCTAssertEqual(first.fingerprint, second.fingerprint)
  }

  func testAPointOutsideEveryViewHasNoTarget() {
    let window = host(Color.clear)
    let outside = CGPoint(x: -100, y: -100)
    XCTAssertEqual(resolver.tapEvidence(in: window.window, at: outside), .failed(.noTargetAtPoint))
  }

  private func cells(in window: HostedWindow) -> [UIView] {
    window.views(UICollectionViewCell.self) as [UIView] + window.views(UITableViewCell.self) as [UIView]
  }
}
#endif
