#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest

@testable import Tugboat

/// `.tugboatScreen` and hosting-controller appearance on hosted views.
final class TugboatScreenTests: XCTestCase {
  private var hosted: HostedWindow?

  override func tearDown() {
    hosted?.close()
    hosted = nil
    super.tearDown()
  }

  /// The top screen after applying queued callbacks.
  private func top(_ tracker: ScreenTracker) -> RouteEntry? {
    tracker.settle()
    return tracker.top
  }

  func testAppearAndReplacementProduceNavigationFacts() throws {
    let clock = ManualClock()
    let tracker = ScreenTracker(clock: clock)
    let window = HostedWindow(Text("Home").modifier(TugboatScreenModifier(name: "Home", tracker: tracker)).id("home"))
    hosted = window
    XCTAssertTrue(window.wait { self.top(tracker)?.name == "Home" })
    let seed = tracker.sessionStartFact(at: clock.now())
    tracker.isRecording = true
    let first = seed.map { [$0] } ?? []
    XCTAssertEqual(first.count, 1)
    let push = first.first?.decodedInput
    XCTAssertEqual(push?["kind"] as? String, "session_start")
    XCTAssertEqual(push?["navigatorId"] as? String, "swiftui-screens")
    let routes = try XCTUnwrap(push?["routes"] as? [[String: Any]])
    let route = try XCTUnwrap(routes.first)
    XCTAssertEqual(route["name"] as? String, "Home")
    XCTAssertEqual(route["type"] as? String, "TugboatScreen")
    let homeId = try XCTUnwrap(route["instanceId"] as? String)

    // A new identity: Home disappears, Detail appears.
    window.hosting?.rootView = AnyView(Text("Detail").modifier(TugboatScreenModifier(name: "Detail", tracker: tracker)).id("detail"))
    XCTAssertTrue(window.wait { self.top(tracker)?.name == "Detail" })
    window.settle()
    let second = tracker.takeFacts()
    XCTAssertEqual(second.count, 1, "the covered Home disappearing changes nothing")
    let next = second.first?.decodedInput
    XCTAssertEqual(next?["kind"] as? String, "push")
    XCTAssertEqual((next?["departing"] as? [String: Any])?["instanceId"] as? String, homeId)
  }

  func testScreenInstanceIdsAreStableAcrossUpdates() {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.isRecording = true
    let window = HostedWindow(Text("A").modifier(TugboatScreenModifier(name: "A", tracker: tracker)))
    hosted = window
    XCTAssertTrue(window.wait { self.top(tracker) != nil })
    let id = tracker.top?.instanceId
    window.hosting?.rootView = AnyView(Text("A changed").modifier(TugboatScreenModifier(name: "A", tracker: tracker)))
    window.settle()
    XCTAssertEqual(top(tracker)?.instanceId, id)
  }

  func testHostingControllerAppearanceIsSilentOnceAScreenIsSeen() {
    let screens = ScreenTracker(clock: ManualClock())
    let tracker = HostingControllerTracker(screens: screens, clock: ManualClock())
    let window = HostedWindow(Text("Plain"))
    hosted = window
    let controller = window.window.rootViewController ?? UIViewController()

    tracker.controller(controller, appeared: true)
    let seed = tracker.sessionStartFact(at: ManualClock().now())
    XCTAssertNotNil(seed)
    XCTAssertEqual(seed?.decodedInput["kind"] as? String, "session_start")
    let routes = seed?.decodedInput["routes"] as? [[String: Any]]
    let route = routes?.first
    XCTAssertEqual(seed?.decodedInput["navigatorId"] as? String, "swiftui-hosting")
    XCTAssertEqual(route?["name"] as? String, RouteKey.hostingKey(controller))
    XCTAssertEqual(route?["type"] as? String, "UIHostingController")

    tracker.isRecording = true
    tracker.controller(UIViewController(), appeared: true)
    XCTAssertTrue(tracker.takeFacts().isEmpty, "not a hosting controller")

    screens.appeared(instanceId: "x", name: "Screen")
    tracker.controller(controller, appeared: false)
    XCTAssertTrue(tracker.takeFacts().isEmpty, "screens win once seen")
  }

  func testQueuedNavigationWhileStoppedIsDropped() {
    let clock = ManualClock()
    let tracker = ScreenTracker(clock: clock)
    tracker.isRecording = false
    let window = HostedWindow(Text("Home").modifier(TugboatScreenModifier(name: "Home", tracker: tracker)).id("home"))
    hosted = window
    XCTAssertTrue(window.wait { self.top(tracker)?.name == "Home" })
    tracker.settle()
    XCTAssertTrue(tracker.takeFacts().isEmpty)
    tracker.isRecording = true
    window.hosting?.rootView = AnyView(Text("Detail").modifier(TugboatScreenModifier(name: "Detail", tracker: tracker)).id("detail"))
    XCTAssertTrue(window.wait { self.top(tracker)?.name == "Detail" })
    let live = tracker.takeFacts()
    XCTAssertEqual(live.count, 1)
    XCTAssertEqual(live.first?.decodedInput["kind"] as? String, "push")
  }

  func testHostingStackIsSeededAfterStopStart() {
    let screens = ScreenTracker(clock: ManualClock())
    let tracker = HostingControllerTracker(screens: screens, clock: ManualClock())
    let window = HostedWindow(Text("Plain"))
    hosted = window
    let controller = window.window.rootViewController ?? UIViewController()
    tracker.isRecording = false
    tracker.controller(controller, appeared: true)
    XCTAssertNotNil(tracker.sessionStartFact(at: ManualClock().now()))
    tracker.isRecording = false
    XCTAssertNotNil(tracker.sessionStartFact(at: ManualClock().now()))
  }

  func testViewControllerAppearanceForwardsAndCallsTheOriginal() {
    final class Probe: UIViewController {
      var didAppear = 0
      override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear += 1
      }
    }
    ViewControllerAppearance.install()
    ViewControllerAppearance.install()
    XCTAssertTrue(ViewControllerAppearance.isInstalled)
    var seen: [(UIViewController, Bool)] = []
    ViewControllerAppearance.observer = { seen.append(($0, $1)) }
    defer { ViewControllerAppearance.observer = nil }

    let probe = Probe()
    probe.viewDidAppear(false)
    probe.viewDidDisappear(false)
    XCTAssertEqual(probe.didAppear, 1)
    XCTAssertEqual(seen.count, 2, "installed once: one notification per call")
    XCTAssertTrue(seen.first?.0 === probe)
    XCTAssertEqual(seen.map { $0.1 }, [true, false])
  }
}
#endif
