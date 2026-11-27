#if canImport(UIKit)
import UIKit
import XCTest

@testable import Tugboat

/// When `AccessibilityIdentitySource` may read the tree, and when it builds
/// it (ADR 0010): the `.off` guarantee, the once-per-process sample and
/// activation, assistive clients, and the OS gate. Every source gets its own
/// `AccessibilityProcessState`, standing in for one process.
final class AccessibilityIdentitySourceTests: XCTestCase {
  private var hosted: HostedWindow?
  private let spy = AccessibilitySpy()
  private let hosting = FakeAXHostingView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
  private let tap = CGPoint(x: 50, y: 120)

  override func setUp() {
    super.setUp()
    hosting.elements = [axElement(CGRect(x: 20, y: 100, width: 100, height: 44), .button)]
    let controller = UIViewController()
    controller.view.addSubview(hosting)
    hosted = HostedWindow(controller: controller)
  }

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  private func source(_ mode: SwiftUIAccessibilityIdentity, process: AccessibilityProcessState = AccessibilityProcessState()) -> AccessibilityIdentitySource {
    AccessibilityIdentitySource(mode: mode, environment: spy.environment, process: process)
  }

  private func leaf(_ source: AccessibilityIdentitySource) -> AccessibilityLeaf? {
    guard let window = hosted?.window else { return nil }
    return source.leaf(at: tap, in: window, root: hosting)
  }

  private let button = AccessibilityLeaf(token: "AXButton", ordinal: 0, role: "button")

  func testOffNeverReadsOrActivatesEvenWithVoiceOverRunning() {
    spy.assistiveClientRunning = true
    let off = source(.off)
    for _ in 0..<3 {
      XCTAssertNil(leaf(off))
    }
    spy.runNextTurn()
    XCTAssertEqual(hosting.reads, 0, "the tree is never read")
    XCTAssertTrue(spy.activated.isEmpty)
    XCTAssertEqual(spy.osReads + spy.assistiveReads + spy.draws, 0, "nothing is even asked")
  }

  func testOffIsTheDefaultAndResolvesAsToday() throws {
    let resolver = AnchorResolver(tags: TagRegistry(), screens: ScreenTracker(clock: ManualClock()))
    let window = try XCTUnwrap(hosted?.window)
    XCTAssertEqual(resolver.tapEvidence(in: window, at: tap), .failed(.noActionableCandidate))
    XCTAssertEqual(hosting.reads, 0)
    XCTAssertEqual(SwiftUIAccessibilityIdentity.off, TugboatConfig(
      collector: .init(baseURL: try XCTUnwrap(URL(string: "https://collector.example.com")), apiKey: "k"),
      app: .init(name: "a", version: "1", buildNumber: "1", appId: "b", installationId: "i")
    ).swiftUIAccessibilityIdentity, "off by default")
  }

  func testTheFirstQualifyingTapSchedulesActivationForTheNextTurnAndResolvesAsToday() {
    let on = source(.on)

    XCTAssertNil(leaf(on), "the first tap resolves as with the option off")
    XCTAssertTrue(spy.activated.isEmpty, "never inside the touch sequence")
    XCTAssertEqual(spy.pending.count, 1)
    XCTAssertEqual(hosting.reads, 0)
    XCTAssertNil(leaf(on), "still waiting for its turn")
    XCTAssertEqual(spy.pending.count, 1, "scheduled once")

    spy.runNextTurn()
    XCTAssertEqual(spy.activated.count, 1)
    XCTAssertTrue(spy.activated.first === hosting, "the tap's hosting view")
    XCTAssertEqual(leaf(on), button, "later taps read the tree")
    XCTAssertEqual(leaf(on), button)
    XCTAssertTrue(spy.pending.isEmpty)
    XCTAssertEqual(spy.activated.count, 1, "once")
  }

  func testActivationIsOncePerProcessAcrossSessions() {
    let process = AccessibilityProcessState()
    let first = source(.on, process: process)
    XCTAssertNil(leaf(first))
    spy.runNextTurn()

    let second = source(.on, process: process)
    XCTAssertEqual(leaf(second), button, "a new session in the same process reads at once")
    XCTAssertTrue(spy.pending.isEmpty)
    XCTAssertEqual(spy.activated.count, 1)
  }

  func testAHostingViewGoneBeforeItsTurnIsNotActivated() {
    let process = AccessibilityProcessState()
    let on = source(.on, process: process)
    XCTAssertNil(leaf(on))
    hosting.removeFromSuperview()
    spy.runNextTurn()
    XCTAssertTrue(spy.activated.isEmpty)
    XCTAssertEqual(process.activation, .none, "a later qualifying tap tries again")
  }

  func testAnAssistiveClientMeansNoActivationButReading() {
    spy.assistiveClientRunning = true
    let on = source(.on)

    XCTAssertEqual(leaf(on), button, "the tree exists: read on the first tap")
    spy.runNextTurn()
    XCTAssertTrue(spy.activated.isEmpty, "no accessibilityActivate()")
    XCTAssertTrue(spy.pending.isEmpty)
  }

  func testTheSampleIsDrawnOncePerProcess() {
    let process = AccessibilityProcessState()
    spy.draw = 0.4
    XCTAssertNil(leaf(source(.sampled(rate: 0.5), process: process)), "sampled in: activation first")
    spy.runNextTurn()
    XCTAssertEqual(leaf(source(.sampled(rate: 0.1), process: process)), button, "the first draw stands")
    XCTAssertEqual(spy.draws, 1)
  }

  func testASampledOutProcessNeverReadsOrActivates() {
    let process = AccessibilityProcessState()
    spy.draw = 0.6
    spy.assistiveClientRunning = true
    for rate in [0.5, 1.0, 0.9] {
      XCTAssertNil(leaf(source(.sampled(rate: rate), process: process)))
    }
    spy.runNextTurn()
    XCTAssertEqual(spy.draws, 1)
    XCTAssertEqual(hosting.reads, 0)
    XCTAssertTrue(spy.activated.isEmpty)
  }

  func testRatesAreClamped() {
    XCTAssertTrue(AccessibilityProcessState().isSampledIn(rate: 2, draw: { 0.999 }))
    XCTAssertFalse(AccessibilityProcessState().isSampledIn(rate: -1, draw: { 0 }))
    XCTAssertFalse(AccessibilityProcessState().isSampledIn(rate: .nan, draw: { 0 }))
    XCTAssertFalse(AccessibilityProcessState().isSampledIn(rate: 0, draw: { 0 }))
    XCTAssertTrue(AccessibilityProcessState().isSampledIn(rate: 1, draw: { 0.999 }))
  }

  func testAnUnverifiedOSMajorBehavesAsOff() {
    for major in [15, 16, 17, 26] {
      spy.osMajor = major
      spy.assistiveClientRunning = true
      XCTAssertNil(leaf(source(.on)), "iOS \(major)")
      XCTAssertNil(leaf(source(.sampled(rate: 1))), "iOS \(major)")
    }
    spy.runNextTurn()
    XCTAssertEqual(hosting.reads, 0)
    XCTAssertTrue(spy.activated.isEmpty)
    XCTAssertEqual(spy.draws, 0)
    XCTAssertEqual(AccessibilityIdentitySource.verifiedMajors, [18])
  }
}
#endif
