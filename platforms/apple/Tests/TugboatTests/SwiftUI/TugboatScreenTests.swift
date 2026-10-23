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

  func testANavigatorNestsTheScreensInsideIt() throws {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.isRecording = true
    let window = HostedWindow(
      Text("Inner")
        .modifier(TugboatScreenModifier(name: "Inner", tracker: tracker))
        .tugboatNavigator("inner")
        .modifier(TugboatScreenModifier(name: "Shell", tracker: tracker))
    )
    hosted = window
    XCTAssertTrue(window.wait { self.top(tracker)?.name == "Inner" })
    let facts = tracker.takeFacts().map { $0.decodedInput }
    func fact(_ name: String) -> [String: Any]? {
      facts.first { ($0["route"] as? [String: Any])?["name"] as? String == name }
    }
    let shell = try XCTUnwrap(fact("Shell"))
    XCTAssertEqual(shell["navigatorId"] as? String, "swiftui-screens")
    XCTAssertNil(shell["parentNavigatorId"], "the root navigator's facts are unchanged")
    let inner = try XCTUnwrap(fact("Inner"))
    XCTAssertEqual(inner["kind"] as? String, "push")
    XCTAssertEqual(inner["navigatorId"] as? String, "swiftui-screens/inner")
    XCTAssertEqual(inner["parentNavigatorId"] as? String, "swiftui-screens")
    XCTAssertEqual(tracker.entries(of: "swiftui-screens")?.map { $0.name }, ["Shell"])
  }

  /// The sheet is presented only once the window is up and Details has
  /// appeared (a sheet presented while the window is created never shows
  /// in the test host). "Not presented" and "landed on the wrong
  /// navigator" fail with different messages.
  func testAScreenPresentedAsASheetIsASheetRouteOnThePresentingNavigator() throws {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.isRecording = true
    let toggle = SheetToggle()
    let window = HostedWindow(SheetPresenter(tracker: tracker, toggle: toggle).tugboatNavigator("tabA"))
    hosted = window
    window.window.makeKeyAndVisible()
    defer {
      toggle.presented = false
      window.window.rootViewController?.dismiss(animated: false)
    }
    XCTAssertTrue(window.wait { self.top(tracker)?.name == "Details" }, "the presenter never appeared")

    toggle.presented = true
    func sheetNavigator() -> String? {
      tracker.settle()
      return tracker.navigatorIds.first { id in tracker.entries(of: id)?.contains { $0.name == "Sheet" } ?? false }
    }
    let presented = window.wait(timeout: 5) { sheetNavigator() != nil }
    XCTAssertTrue(presented, "the sheet was not presented: no Sheet route on any navigator")
    guard presented else { return }

    XCTAssertEqual(sheetNavigator(), "swiftui-screens/tabA", "the sheet content did not get the presenter's navigator through the environment")
    let entry = tracker.entries(of: "swiftui-screens/tabA")?.first { $0.name == "Sheet" }
    XCTAssertEqual(entry?.overlayKind, .sheet)
    let facts = tracker.takeFacts().map { $0.decodedInput }
    let push = facts.first { ($0["route"] as? [String: Any])?["name"] as? String == "Sheet" }
    XCTAssertEqual(push?["kind"] as? String, "push")
    XCTAssertEqual((push?["route"] as? [String: Any])?["overlayKind"] as? String, "sheet")
    XCTAssertEqual((push?["departing"] as? [String: Any])?["name"] as? String, "Details")
  }

  func testTheRouteKeyFollowsTheVisibleChainTop() {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.appeared(instanceId: "home", name: "Home")
    tracker.appeared(instanceId: "inner", name: "Inner", scope: NavigatorScope.root.hosted(by: "home").nested("pane"))
    tracker.settle()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    window.addSubview(view)
    let nested = RouteKey.resolve(for: view, in: window, screen: tracker.visibleTop)
    XCTAssertEqual(nested.value, "Inner")
    XCTAssertEqual(nested.confidence, .high)

    tracker.disappeared(instanceId: "inner")
    tracker.settle()
    XCTAssertEqual(RouteKey.resolve(for: view, in: window, screen: tracker.visibleTop).value, "Home")
  }

  func testStopThenStartSeedsEveryNavigatorWithTheVisibleChainLast() throws {
    let clock = ManualClock()
    let screens = ScreenTracker(clock: clock)
    let sink = RecordingSink()
    let frames = ManualFrames()
    let adapter = SwiftUIAdapter(
      sink: sink, hostClock: clock, frames: frames, trackHostingControllers: false, screens: screens)
    adapter.start()
    let tabA = NavigatorScope.root.hosted(by: "shell").nested("tabA")
    screens.appeared(instanceId: "shell", name: "Shell")
    screens.appeared(instanceId: "home", name: "Home", scope: tabA)
    frames.runFrame()
    adapter.stop()
    screens.appeared(instanceId: "details", name: "Details", scope: tabA)
    let posted = sink.messages.count

    adapter.start()
    frames.runFrame()
    adapter.stop()
    let seeds = sink.messages.dropFirst(posted)
      .filter { $0.type == FactTypes.navigation }
      .compactMap { decodeObject($0.inputJSON) }
    XCTAssertEqual(seeds.map { $0["kind"] as? String }, ["session_start", "session_start"])
    XCTAssertEqual(seeds.map { $0["navigatorId"] as? String }, ["swiftui-screens", "swiftui-screens/tabA"])
    XCTAssertEqual(seeds.map { $0["parentNavigatorId"] as? String }, [nil, "swiftui-screens"])
    let routes = try XCTUnwrap(seeds.last?["routes"] as? [[String: Any]])
    XCTAssertEqual(routes.map { $0["name"] as? String }, ["Home", "Details"], "the push made while stopped is in the seed")
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

/// Presents the sheet when the test says so.
private final class SheetToggle: ObservableObject {
  @Published var presented = false
}

/// Details, presenting a `.sheet` screen from its navigator.
private struct SheetPresenter: View {
  let tracker: ScreenTracker
  @ObservedObject var toggle: SheetToggle

  var body: some View {
    Text("Details")
      .modifier(TugboatScreenModifier(name: "Details", tracker: tracker))
      .sheet(isPresented: $toggle.presented) {
        Text("Sheet").modifier(TugboatScreenModifier(name: "Sheet", presentation: .sheet, tracker: tracker))
      }
  }
}
#endif
