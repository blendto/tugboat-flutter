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
    HostingControllerTracker.shared.reset()
    super.tearDown()
  }

  /// The top screen after applying queued callbacks.
  private func top(_ tracker: ScreenTracker) -> RouteEntry? {
    tracker.settle()
    return tracker.visibleTop
  }

  func testAppearAndReplacementProduceNavigationFacts() throws {
    let clock = ManualClock()
    let tracker = ScreenTracker(clock: clock)
    let window = HostedWindow(Text("Home").modifier(TugboatScreenModifier(name: "Home", tracker: tracker)).id("home"))
    hosted = window
    XCTAssertTrue(window.wait { self.top(tracker)?.name == "Home" })
    let first = tracker.sessionStartFacts(at: clock.now())
    tracker.isRecording = true
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
    let id = tracker.visibleTop?.instanceId
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

  func testHostingStackIsSeededAfterStopStart() throws {
    let clock = ManualClock()
    let screens = ScreenTracker(clock: clock)
    let sink = RecordingSink()
    let frames = ManualFrames()
    let adapter = SwiftUIAdapter(
      sink: sink, hostClock: clock, frames: frames, trackHostingControllers: true, screens: screens)
    adapter.start()
    let window = HostedWindow(Text("First"))
    hosted = window
    XCTAssertTrue(window.wait { HostingControllerTracker.shared.sessionStartFact(at: clock.now()) != nil })
    let firstSeed = try XCTUnwrap(HostingControllerTracker.shared.sessionStartFact(at: clock.now()))
    let firstTop = (firstSeed.decodedInput["routes"] as? [[String: Any]])?.last?["instanceId"] as? String
    adapter.stop()

    let replacement = UIHostingController(rootView: Text("Second"))
    window.window.rootViewController = replacement
    replacement.viewDidAppear(false)

    adapter.start()
    frames.runFrame()
    let lastSeed = sink.messages.reversed().first { message in
      message.type == FactTypes.navigation &&
        (decodeObject(message.inputJSON)?["kind"] as? String) == "session_start"
    }
    let seed = try XCTUnwrap(lastSeed)
    let routes = decodeObject(seed.inputJSON)?["routes"] as? [[String: Any]]
    // The replacement shown while stopped is the seeded top, not the first host.
    XCTAssertNotNil(firstTop)
    XCTAssertNotEqual(routes?.last?["instanceId"] as? String, firstTop)
    adapter.stop()
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
    let previous = ViewControllerAppearance.observer
    ViewControllerAppearance.observer = { seen.append(($0, $1)) }
    defer { ViewControllerAppearance.observer = previous }

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
