#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// Anchors refined by the accessibility tree (ADR 0010, "Anchors"), through
/// `AnchorResolver` and a source whose process already activated the tree;
/// and the taps that must never ask, byte for byte as with the option off.
final class AccessibilityIdentityAnchorTests: XCTestCase {
  private var hosted: HostedWindow?
  private let registry = TagRegistry()
  private let screens = ScreenTracker(clock: ManualClock())
  private let spy = AccessibilitySpy()

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private func activatedSource() -> AccessibilityIdentitySource {
    let process = AccessibilityProcessState()
    process.activation = .done
    return AccessibilityIdentitySource(mode: .on, environment: spy.environment, process: process)
  }

  private func resolver(_ accessibility: AccessibilityLeafSource?) -> AnchorResolver {
    AnchorResolver(tags: registry, screens: screens, accessibility: accessibility)
  }

  /// A UIKit screen with a fake hosting view filling it, on route `name`.
  private func hostFake(_ elements: [NSObject], screen name: String = "Pay") -> FakeAXHostingView {
    let hosting = FakeAXHostingView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
    hosting.elements = elements
    let controller = UIViewController()
    controller.view.addSubview(hosting)
    hosted = HostedWindow(controller: controller)
    screens.appeared(instanceId: "screen-1", name: name)
    return hosting
  }

  private func anchor(_ evidence: TapEvidence, file: StaticString = #filePath, line: UInt = #line) -> TargetAnchor? {
    guard case let .anchor(anchor) = evidence else {
      XCTFail("expected an anchor, got \(evidence)", file: file, line: line)
      return nil
    }
    return anchor
  }

  func testAnUntaggedButtonGetsAnAXButtonSegmentAndItsRole() throws {
    _ = hostFake([
      axElement(CGRect(x: 20, y: 100, width: 100, height: 44), .button),
      axElement(CGRect(x: 20, y: 200, width: 100, height: 44), .image),
      axElement(CGRect(x: 20, y: 300, width: 100, height: 44), .button),
    ])
    let window = try XCTUnwrap(hosted?.window)

    let resolved = try XCTUnwrap(anchor(resolver(activatedSource()).tapEvidence(in: window, at: CGPoint(x: 60, y: 320))))
    XCTAssertTrue(resolved.canonicalPath.hasSuffix("AXButton#1"), resolved.canonicalPath)
    XCTAssertEqual(resolved.role, "button")
    XCTAssertEqual(resolved.widgetType, "SwiftUIView")
    XCTAssertEqual(resolved.confidence, .low, "a structural path outside a list cell")
    XCTAssertNil(resolved.tagFingerprint)
    XCTAssertNil(resolved.tag)
    XCTAssertNil(resolved.enabled)
    XCTAssertEqual(resolved.actions, [])
    XCTAssertEqual(resolved.routeKey, "Pay")
    XCTAssertEqual(resolved.fingerprint, IdentityHash.fingerprint([(key: "routeKey", value: "Pay"), (key: "path", value: resolved.canonicalPath)]))

    let today = resolver(nil).tapEvidence(in: window, at: CGPoint(x: 60, y: 320))
    XCTAssertEqual(today, .failed(.noActionableCandidate), "without the source")
  }

  func testUnmappedTraitsGiveAnAXElementWithoutRole() throws {
    _ = hostFake([axElement(CGRect(x: 20, y: 100, width: 100, height: 44), .staticText)])
    let window = try XCTUnwrap(hosted?.window)

    let resolved = try XCTUnwrap(anchor(resolver(activatedSource()).tapEvidence(in: window, at: CGPoint(x: 60, y: 120))))
    XCTAssertTrue(resolved.canonicalPath.hasSuffix("AXElement#0"), resolved.canonicalPath)
    XCTAssertNil(resolved.role)
    XCTAssertNil(resolved.json["role"])
  }

  func testAnIdentifiedElementIsAPathSegmentAndItsIdentifierNeverReachesTheAnchor() throws {
    let secret = "user-ada@example.com"
    _ = hostFake([
      axElement(CGRect(x: 20, y: 100, width: 100, height: 44), .button, identifier: "row_41"),
      axElement(CGRect(x: 20, y: 200, width: 100, height: 44), .button, identifier: secret),
    ])
    let window = try XCTUnwrap(hosted?.window)

    let resolved = try XCTUnwrap(anchor(resolver(activatedSource()).tapEvidence(in: window, at: CGPoint(x: 60, y: 220))))
    XCTAssertTrue(resolved.canonicalPath.hasSuffix("AXIdentified#1"), resolved.canonicalPath)
    XCTAssertNil(resolved.role, "an identified element gets no role")
    XCTAssertNil(resolved.tag, "the identifier is not an alias")
    XCTAssertNil(resolved.tagFingerprint)
    XCTAssertNotEqual(resolved.confidence, .high)
    let json = TapEvidence.anchor(resolved).json.json
    XCTAssertFalse(json.contains("ada"), json)
    XCTAssertFalse(json.contains("row_41"), json)
    XCTAssertFalse(json.contains("\"tag\""), json)
    XCTAssertFalse(json.contains("tagFingerprint"), json)
  }

  func testATapOnAListCellWithNoControlGetsADeeperMediumConfidencePath() throws {
    let hosting = FakeAXHostingView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
    hosting.elements = [
      axElement(CGRect(x: 0, y: 0, width: 200, height: 60), .staticText),
      axElement(CGRect(x: 300, y: 10, width: 80, height: 40), .button),
    ]
    let rows = OneRowTable(content: hosting)
    let controller = UIViewController()
    let table = UITableView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
    table.dataSource = rows
    table.rowHeight = 60
    table.contentInsetAdjustmentBehavior = .never
    controller.view.addSubview(table)
    hosted = HostedWindow(controller: controller)
    screens.appeared(instanceId: "screen-1", name: "Inbox")
    let window = try XCTUnwrap(hosted?.window)
    XCTAssertTrue(try XCTUnwrap(hosted).wait { hosting.window != nil })
    let point = hosting.convert(CGPoint(x: 340, y: 30), to: window)

    let today = try XCTUnwrap(anchor(resolver(nil).tapEvidence(in: window, at: point)))
    XCTAssertTrue(today.canonicalPath.hasSuffix("[item:0.0]/Cell#0"), today.canonicalPath)
    let refined = try XCTUnwrap(anchor(resolver(activatedSource()).tapEvidence(in: window, at: point)))
    XCTAssertEqual(refined.canonicalPath, today.canonicalPath + "/AXButton#0")
    XCTAssertEqual(refined.confidence, .medium, "inside a list cell")
    XCTAssertEqual(refined.role, "button")
    XCTAssertNotEqual(refined.fingerprint, today.fingerprint, "a deeper path is a different fingerprint")
  }

  func testATapTheTreeCannotAnswerKeepsTodaysResult() throws {
    _ = hostFake([axElement(CGRect(x: 20, y: 100, width: 100, height: 44), .button)])
    let window = try XCTUnwrap(hosted?.window)
    XCTAssertEqual(resolver(activatedSource()).tapEvidence(in: window, at: CGPoint(x: 300, y: 700)), .failed(.noActionableCandidate))
  }

  // MARK: Taps that never ask

  func testTaggedTapsAreByteIdenticalAndNeverAsk() throws {
    let window = HostedWindow(
      VStack(spacing: 40) {
        Button("Stop") {}.modifier(TugboatTagModifier(tag: "stop", registry: registry))
        ScrollView {
          Button("Add") {}.modifier(TugboatTagModifier(tag: "add", registry: registry))
        }
        .frame(height: 120)
        List {
          Button("Row") {}.modifier(TugboatTagModifier(tag: "row", registry: registry))
        }
      }
      .modifier(TugboatScreenModifier(name: "Home", tracker: screens))
    )
    hosted = window
    let tags = ["stop", "add", "row"]
    XCTAssertTrue(window.wait { tags.allSatisfy { tag in self.registry.all.contains { $0.tugboatTag == tag && $0.window != nil } } })
    window.settle()
    let source = AlwaysAnsweringLeafSource()
    for tag in tags {
      let marker = try XCTUnwrap(registry.all.first { $0.tugboatTag == tag && $0.window != nil })
      let frame = window.frame(of: marker)
      try assertUnchanged(at: CGPoint(x: frame.midX, y: frame.midY), in: window.window, source: source, tag)
    }
    XCTAssertEqual(source.asked, 0)
  }

  func testUIKitControlAndTextInputTapsAreByteIdenticalAndNeverAsk() throws {
    let controller = UIViewController()
    let button = UIButton(type: .system)
    button.setTitle("Pay", for: .normal)
    button.frame = CGRect(x: 40, y: 200, width: 120, height: 44)
    let field = UITextField(frame: CGRect(x: 40, y: 300, width: 200, height: 44))
    let hosting = FakeAXHostingView(frame: CGRect(x: 0, y: 400, width: 390, height: 200))
    let inner = UIButton(type: .system)
    inner.frame = CGRect(x: 40, y: 40, width: 120, height: 44)
    hosting.addSubview(inner)
    [button, field, hosting].forEach(controller.view.addSubview)
    let window = HostedWindow(controller: controller)
    hosted = window
    let source = AlwaysAnsweringLeafSource()

    try assertUnchanged(at: CGPoint(x: 100, y: 222), in: window.window, source: source, "UIButton")
    try assertUnchanged(at: CGPoint(x: 100, y: 322), in: window.window, source: source, "UITextField")
    try assertUnchanged(at: CGPoint(x: 100, y: 462), in: window.window, source: source, "a UIKit button in a hosting view")
    XCTAssertEqual(source.asked, 0)

    // The fake does answer a qualifying tap: bare drawing in the hosting view.
    let refined = try XCTUnwrap(anchor(resolver(source).tapEvidence(in: window.window, at: CGPoint(x: 300, y: 550))))
    XCTAssertTrue(refined.canonicalPath.hasSuffix("AXButton#0"), refined.canonicalPath)
    XCTAssertEqual(source.asked, 1)
  }

  private func assertUnchanged(
    at point: CGPoint, in window: UIWindow, source: AccessibilityLeafSource, _ name: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let today = resolver(nil).tapEvidence(in: window, at: point)
    let withSource = resolver(source).tapEvidence(in: window, at: point)
    guard case .anchor = today else {
      return XCTFail("\(name) resolves to an anchor today, got \(today)", file: file, line: line)
    }
    XCTAssertEqual(withSource, today, name, file: file, line: line)
    XCTAssertEqual(withSource.json.json, today.json.json, "\(name): byte for byte", file: file, line: line)
  }
}

/// One table row whose content is `content`.
private final class OneRowTable: NSObject, UITableViewDataSource {
  let content: UIView

  init(content: UIView) {
    self.content = content
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    1
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    content.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 60)
    cell.contentView.addSubview(content)
    return cell
  }
}
#endif
