#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// ADR 0010 on a real SwiftUI hosting view with no assistive client
/// attached (a unit-test process on the simulator). Activation cannot be
/// undone for the life of the process, so this is its own test bundle: the
/// `TugboatTests` bundle never sees a built tree.
///
/// The OS gate is overridden to a verified major, so CI's simulator (not
/// iOS 18) runs the path. `TBDUMP` lines record what the simulator exposed.
final class AccessibilityActivationTests: XCTestCase {
  private var window: UIWindow?

  override func tearDown() {
    window?.isHidden = true
    window?.rootViewController = nil
    window = nil
    super.tearDown()
  }

  func testActivationBuildsTheTreeAndTapsResolveByElementFrame() throws {
    let frames = RecordedFrames()
    let screens = ScreenTracker()
    let controller = UIHostingController(rootView: Fixture(frames: frames).modifier(TugboatScreenModifier(name: "Checkout", tracker: screens)))
    let window = host(controller)
    XCTAssertTrue(wait { ["pay", "help", "row"].allSatisfy { frames.frames[$0] != nil } })
    settle(0.5)
    let hosting = try XCTUnwrap(controller.view)
    print("TBDUMP iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion), VoiceOver \(UIAccessibility.isVoiceOverRunning), Switch Control \(UIAccessibility.isSwitchControlRunning)")
    print("TBDUMP hosting view \(type(of: hosting)): \(Self.elementCount(of: hosting)) accessibility elements before activation")
    XCTAssertEqual(Self.elementCount(of: hosting), 0, "no tree without an assistive client")

    var environment = AccessibilityEnvironment.live
    environment.osMajor = { AccessibilityIdentitySource.verifiedMajors.min() ?? 18 }
    let process = AccessibilityProcessState()
    let source = AccessibilityIdentitySource(mode: .on, environment: environment, process: process)
    let resolver = AnchorResolver(tags: TagRegistry(), screens: screens, accessibility: source)
    let pay = try XCTUnwrap(frames.centre("pay"))

    XCTAssertEqual(resolver.tapEvidence(in: window, at: pay), .failed(.noActionableCandidate), "the first tap resolves as today")
    XCTAssertEqual(process.activation, .scheduled, "activation waits for the next turn")
    XCTAssertTrue(wait { process.activation == .done })
    settle(0.5)
    let after = Self.elementCount(of: hosting)
    print("TBDUMP hosting view: \(after) accessibility elements after activation")
    dumpTree(hosting, in: window)
    XCTAssertGreaterThan(after, 0, "accessibilityActivate() built the tree")

    let payAnchor = try XCTUnwrap(anchor(resolver.tapEvidence(in: window, at: pay)))
    print("TBDUMP pay: \(payAnchor.canonicalPath) role \(payAnchor.role ?? "nil") \(payAnchor.confidence)")
    XCTAssertEqual(payAnchor.canonicalPath, "AXButton#0")
    XCTAssertEqual(payAnchor.role, "button")
    XCTAssertEqual(payAnchor.widgetType, "SwiftUIView")
    XCTAssertEqual(payAnchor.routeKey, "Checkout")

    let help = try XCTUnwrap(anchor(resolver.tapEvidence(in: window, at: try XCTUnwrap(frames.centre("help")))))
    let helpJSON = TapEvidence.anchor(help).json.json
    print("TBDUMP help: \(help.canonicalPath) role \(help.role ?? "nil")")
    XCTAssertEqual(help.canonicalPath, "AXIdentified#0")
    XCTAssertNil(help.role)
    XCTAssertFalse(helpJSON.contains("ada"), helpJSON)

    let rowPoint = try XCTUnwrap(frames.centre("row"))
    let lineage = window.hitTest(rowPoint, with: nil).flatMap { ViewTree.lineage(from: window, to: $0) } ?? []
    print("TBDUMP row lineage: \(lineage.map { "\(type(of: $0.view)):\($0.kind)" })")
    let row = try XCTUnwrap(anchor(resolver.tapEvidence(in: window, at: rowPoint)))
    print("TBDUMP row: \(row.canonicalPath) role \(row.role ?? "nil") \(row.confidence)")
    XCTAssertTrue(row.canonicalPath.contains("Cell#0/AX"), "a button in a list row refines the cell: \(row.canonicalPath)")
    XCTAssertEqual(row.confidence, .medium)
  }

  // MARK: Fixture

  private struct Fixture: View {
    let frames: RecordedFrames

    var body: some View {
      VStack(spacing: 40) {
        Button("Pay") {}.record("pay", frames)
        Button("Help") {}.accessibilityIdentifier("help-ada@example.com").record("help", frames)
        Text("Hello")
        List {
          ForEach(0..<3, id: \.self) { index in
            if index == 1 {
              Button("Row \(index)") {}.record("row", frames)
            } else {
              Button("Row \(index)") {}
            }
          }
        }
        .frame(height: 260)
      }
    }
  }

  // MARK: Support

  private func anchor(_ evidence: TapEvidence, file: StaticString = #filePath, line: UInt = #line) -> TargetAnchor? {
    guard case let .anchor(anchor) = evidence else {
      XCTFail("expected an anchor, got \(evidence)", file: file, line: line)
      return nil
    }
    return anchor
  }

  private func host(_ controller: UIViewController) -> UIWindow {
    let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
      window = UIWindow(windowScene: scene)
      window.frame = frame
    } else {
      window = UIWindow(frame: frame)
    }
    window.rootViewController = controller
    window.isHidden = false
    self.window = window
    settle()
    return window
  }

  private func settle(_ seconds: TimeInterval = 0.25) {
    window?.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    window?.layoutIfNeeded()
  }

  /// The default timeout is a progress wait, not a speed bound: CI runners stall for seconds.
  private func wait(timeout: TimeInterval = 30, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { return false }
      settle(0.05)
    }
    return true
  }

  private static func children(of node: NSObject) -> [NSObject] {
    if let elements = node.accessibilityElements {
      return elements.compactMap { $0 as? NSObject }
    }
    let count = node.accessibilityElementCount()
    guard count > 0, count != NSNotFound else { return [] }
    return (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
  }

  private static func elementCount(of node: NSObject) -> Int {
    children(of: node).count
  }

  /// The tree as the simulator built it: class, element or container,
  /// traits, whether an identifier is set (never its value), frame.
  private func dumpTree(_ node: NSObject, in window: UIWindow, depth: Int = 0) {
    guard depth < 8 else { return }
    for child in Self.children(of: node) {
      // SwiftUI's `AccessibilityNode` answers the getter without declaring
      // `UIAccessibilityIdentification`, so the cast alone misses it.
      let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
      let conforms = child is UIAccessibilityIdentification
      let value = child.responds(to: getter) ? child.perform(getter)?.takeUnretainedValue() as? String : nil
      let identified = !(value ?? "").isEmpty
      let frame = window.convert(child.accessibilityFrame, from: window.screen.coordinateSpace)
      print("TBDUMP \(String(repeating: "  ", count: depth))\(type(of: child)) element \(child.isAccessibilityElement) traits \(child.accessibilityTraits.rawValue) identified \(identified) (conforms \(conforms)) frame \(frame)")
      dumpTree(child, in: window, depth: depth + 1)
    }
  }
}

/// `.global` frames the fixture's views report (the window sits at the
/// screen origin, so these are window points).
private final class RecordedFrames {
  var frames: [String: CGRect] = [:]

  func centre(_ name: String) -> CGPoint? {
    frames[name].map { CGPoint(x: $0.midX, y: $0.midY) }
  }
}

private extension View {
  func record(_ name: String, _ frames: RecordedFrames) -> some View {
    background(GeometryReader { proxy in
      Color.clear
        .onAppear { frames.frames[name] = proxy.frame(in: .global) }
        .onChange(of: proxy.frame(in: .global)) { frames.frames[name] = $0 }
    })
  }
}
#endif
