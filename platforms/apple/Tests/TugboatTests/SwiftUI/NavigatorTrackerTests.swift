import XCTest

@testable import Tugboat

/// Nested navigators (`.tugboatNavigator`) and presentation kinds
/// (`.tugboatScreen(_:presentation:)`) in `ScreenTracker`, without UIKit:
/// the scopes the modifiers put in the environment are built by hand.
final class NavigatorTrackerTests: XCTestCase {
  private let root = ScreenTracker.navigatorId

  private func recordingTracker() -> ScreenTracker {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.isRecording = true
    return tracker
  }

  /// The scope inside `.tugboatNavigator(name)` placed inside the screen `host`.
  private func scope(_ name: String, in outer: NavigatorScope = .root, hostedBy host: String?) -> NavigatorScope {
    (host.map { outer.hosted(by: $0) } ?? outer).nested(name)
  }

  private func seeds(_ tracker: ScreenTracker) -> [[String: Any]] {
    tracker.sessionStartFacts(at: ManualClock().now()).map { $0.decodedInput }
  }

  private func names(_ seed: [String: Any]) -> [String] {
    ((seed["routes"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
  }

  // MARK: Root navigator compatibility

  /// The facts the root navigator sent before nested navigators and
  /// presentation kinds existed (adr-0009-shared-engine @ b693203, run on
  /// the Linux pre-check toolchain); they must not change by one byte.
  private static let oldRootFacts = [
    "{\"kind\":\"push\",\"navigatorId\":\"swiftui-screens\",\"route\":{\"instanceId\":\"a\",\"name\":\"Home\",\"type\":\"TugboatScreen\",\"overlayKind\":\"page\",\"transitionMs\":0}}",
    "{\"kind\":\"push\",\"navigatorId\":\"swiftui-screens\",\"route\":{\"instanceId\":\"b\",\"name\":\"Detail\",\"type\":\"TugboatScreen\",\"overlayKind\":\"page\",\"transitionMs\":350},\"departing\":{\"instanceId\":\"a\",\"name\":\"Home\",\"type\":\"TugboatScreen\"}}",
    "{\"kind\":\"pop\",\"navigatorId\":\"swiftui-screens\",\"route\":{\"instanceId\":\"a\",\"name\":\"Home\",\"type\":\"TugboatScreen\",\"overlayKind\":\"page\",\"transitionMs\":350},\"departing\":{\"instanceId\":\"b\",\"name\":\"Detail\",\"type\":\"TugboatScreen\"}}",
  ]
  private static let oldRootSeed =
    "{\"kind\":\"session_start\",\"navigatorId\":\"swiftui-screens\",\"routes\":[{\"instanceId\":\"a\",\"name\":\"Home\",\"type\":\"TugboatScreen\",\"overlayKind\":\"page\",\"transitionMs\":0},{\"instanceId\":\"b\",\"name\":\"Detail\",\"type\":\"TugboatScreen\",\"overlayKind\":\"page\",\"transitionMs\":0}]}"

  private func rootPushAndPop(_ appear: (ScreenTracker, String, String) -> Void) -> (facts: [String], seed: [String]) {
    let tracker = recordingTracker()
    appear(tracker, "a", "Home")
    var facts = tracker.takeFacts()
    appear(tracker, "b", "Detail")
    facts += tracker.takeFacts()
    let seed = tracker.sessionStartFacts(at: ManualClock().now()).map { $0.input.json }
    tracker.disappeared(instanceId: "b")
    facts += tracker.takeFacts()
    return (facts.map { $0.input.json }, seed)
  }

  func testRootPushAndPopWithAnExplicitPageAreTheOldFacts() {
    let explicit = rootPushAndPop { $0.appeared(instanceId: $1, name: $2, overlayKind: TugboatScreenPresentation.page.overlayKind, scope: .root) }
    XCTAssertEqual(explicit.facts, NavigatorTrackerTests.oldRootFacts)
    XCTAssertEqual(explicit.seed, [NavigatorTrackerTests.oldRootSeed])
  }

  func testRootPushAndPopWithTheDefaultsAreTheOldFacts() {
    let automatic = rootPushAndPop { $0.appeared(instanceId: $1, name: $2, overlayKind: TugboatScreenPresentation.automatic.overlayKind) }
    let defaults = rootPushAndPop { $0.appeared(instanceId: $1, name: $2) }
    XCTAssertEqual(automatic.facts, NavigatorTrackerTests.oldRootFacts)
    XCTAssertEqual(defaults.facts, NavigatorTrackerTests.oldRootFacts)
    XCTAssertEqual(automatic.seed, [NavigatorTrackerTests.oldRootSeed])
    XCTAssertEqual(defaults.seed, [NavigatorTrackerTests.oldRootSeed])
  }

  // MARK: Presentation

  func testPresentationKinds() {
    XCTAssertEqual(TugboatScreenPresentation.automatic.overlayKind, .page, "automatic is page in this release")
    XCTAssertEqual(TugboatScreenPresentation.page.overlayKind, .page)
    XCTAssertEqual(TugboatScreenPresentation.sheet.overlayKind, .sheet)
    XCTAssertEqual(TugboatScreenPresentation.dialog.overlayKind, .dialog)
    XCTAssertEqual(TugboatScreenPresentation.popup.overlayKind, .popup)
  }

  func testASheetScreenIsASheetRouteOnThePresentingNavigator() throws {
    let tracker = recordingTracker()
    tracker.appeared(instanceId: "home", name: "Home")
    _ = tracker.takeFacts()
    tracker.appeared(instanceId: "sheet", name: "Sheet", overlayKind: .sheet, scope: NavigatorScope.root.hosted(by: "home"))
    let push = try XCTUnwrap(tracker.takeFacts().first)
    XCTAssertEqual(
      push.input.json,
      "{\"kind\":\"push\",\"navigatorId\":\"swiftui-screens\",\"route\":{\"instanceId\":\"sheet\",\"name\":\"Sheet\",\"type\":\"TugboatScreen\",\"overlayKind\":\"sheet\",\"transitionMs\":350},\"departing\":{\"instanceId\":\"home\",\"name\":\"Home\",\"type\":\"TugboatScreen\"}}"
    )

    // Dismissing the sheet is the existing pop back to the presenter.
    tracker.disappeared(instanceId: "sheet")
    let pop = try XCTUnwrap(tracker.takeFacts().first?.decodedInput)
    XCTAssertEqual(pop["kind"] as? String, "pop")
    XCTAssertEqual((pop["route"] as? [String: Any])?["name"] as? String, "Home")
    XCTAssertEqual((pop["departing"] as? [String: Any])?["instanceId"] as? String, "sheet")
  }

  // MARK: Nesting

  func testANestedNavigatorsFactsNameItsParent() throws {
    let tracker = recordingTracker()
    let inner = scope("inner", hostedBy: "shell")
    XCTAssertEqual(inner.navigatorId, "swiftui-screens/inner")
    XCTAssertEqual(inner.parentNavigatorId, root)
    tracker.appeared(instanceId: "shell", name: "Shell")
    tracker.appeared(instanceId: "a", name: "A", scope: inner)
    let first = tracker.takeFacts().map { $0.input.json }
    XCTAssertEqual(first, [
      "{\"kind\":\"push\",\"navigatorId\":\"swiftui-screens\",\"route\":{\"instanceId\":\"shell\",\"name\":\"Shell\",\"type\":\"TugboatScreen\",\"overlayKind\":\"page\",\"transitionMs\":0}}",
      "{\"kind\":\"push\",\"navigatorId\":\"swiftui-screens/inner\",\"parentNavigatorId\":\"swiftui-screens\",\"route\":{\"instanceId\":\"a\",\"name\":\"A\",\"type\":\"TugboatScreen\",\"overlayKind\":\"page\",\"transitionMs\":0}}",
    ])

    tracker.appeared(instanceId: "b", name: "B", scope: inner)
    tracker.disappeared(instanceId: "b")
    let later = tracker.takeFacts().map { $0.decodedInput }
    XCTAssertEqual(later.map { $0["kind"] as? String }, ["push", "pop"])
    XCTAssertEqual(later.map { $0["navigatorId"] as? String }, ["swiftui-screens/inner", "swiftui-screens/inner"])
    XCTAssertEqual(later.map { $0["parentNavigatorId"] as? String }, [root, root])
    XCTAssertEqual(tracker.entries(of: root)?.map { $0.name }, ["Shell"], "the inner screens are not on the root")
  }

  func testNavigatorScopes() {
    let outer = scope("outer", hostedBy: "s1")
    XCTAssertEqual(outer.levels, [NavigatorScope.Level(navigatorId: "swiftui-screens/outer", parentNavigatorId: root, hostRouteInstanceId: "s1")])
    XCTAssertNil(outer.hostRouteInstanceId, "a navigator starts with no host screen of its own")
    let inner = scope("inner", in: outer, hostedBy: "s2")
    XCTAssertEqual(inner.navigatorId, "swiftui-screens/inner")
    XCTAssertEqual(inner.parentNavigatorId, "swiftui-screens/outer")
    XCTAssertEqual(inner.levels.last?.hostRouteInstanceId, "s2")
    let direct = outer.nested("direct")
    XCTAssertNil(direct.levels.last?.hostRouteInstanceId, "no screen between the two navigators")
    XCTAssertEqual(outer.nested("outer"), outer, "a navigator is never its own parent")
    var deep = NavigatorScope.root
    for index in 0..<(NavigatorScope.maxDepth + 4) {
      deep = deep.nested("n\(index)")
    }
    XCTAssertEqual(deep.levels.count, NavigatorScope.maxDepth, "deeper navigators stay on the deepest one")
    XCTAssertEqual(NavigatorScope.root.navigatorId, root)
    XCTAssertNil(NavigatorScope.root.parentNavigatorId)
  }

  // MARK: Session start

  /// Root `[Shell]`; `tabA` (hosted by Shell) `[Home, Details, SheetRoot(sheet)]`;
  /// `homeInner` (hosted by the covered Home) `[Pane]`; `sheetNav` (hosted
  /// by SheetRoot) `[SheetDetail]`.
  private func shellWithTabAndSheet(_ tracker: ScreenTracker) {
    let tabA = scope("tabA", hostedBy: "shell")
    tracker.appeared(instanceId: "shell", name: "Shell")
    tracker.appeared(instanceId: "home", name: "Home", scope: tabA)
    tracker.appeared(instanceId: "pane", name: "Pane", scope: scope("homeInner", in: tabA, hostedBy: "home"))
    tracker.settle()
    tracker.appeared(instanceId: "details", name: "Details", scope: tabA)
    tracker.settle()
    tracker.appeared(instanceId: "sheetRoot", name: "SheetRoot", overlayKind: .sheet, scope: tabA.hosted(by: "details"))
    tracker.appeared(instanceId: "sheetDetail", name: "SheetDetail", scope: scope("sheetNav", in: tabA, hostedBy: "sheetRoot"))
    tracker.settle()
  }

  func testSessionStartSeedsEveryNavigatorWithTheVisibleChainLast() {
    let tracker = ScreenTracker(clock: ManualClock())
    shellWithTabAndSheet(tracker)
    let seeds = seeds(tracker)
    XCTAssertEqual(seeds.map { $0["navigatorId"] as? String }, [
      root, "swiftui-screens/homeInner", "swiftui-screens/tabA", "swiftui-screens/sheetNav",
    ])
    XCTAssertEqual(seeds.map { $0["parentNavigatorId"] as? String }, [
      nil, "swiftui-screens/tabA", root, "swiftui-screens/tabA",
    ])
    XCTAssertEqual(seeds.map { names($0) }, [["Shell"], ["Pane"], ["Home", "Details", "SheetRoot"], ["SheetDetail"]])
    XCTAssertTrue(seeds.allSatisfy { $0["kind"] as? String == "session_start" })
    let sheetRoute = (seeds[2]["routes"] as? [[String: Any]])?.last
    XCTAssertEqual(sheetRoute?["overlayKind"] as? String, "sheet")
    XCTAssertEqual(sheetRoute?["transitionMs"] as? Int, 0)
    XCTAssertEqual(tracker.visibleTop?.name, "SheetDetail", "the last seed's top")
  }

  func testSessionStartWithOnlyTheRootIsOneSeed() {
    let tracker = ScreenTracker(clock: ManualClock())
    XCTAssertTrue(seeds(tracker).isEmpty, "nothing on screen: no seed")
    tracker.appeared(instanceId: "a", name: "Home")
    XCTAssertEqual(seeds(tracker).map { $0["navigatorId"] as? String }, [root])
  }

  // MARK: Child cleanup

  func testAChildNavigatorIsForgottenWhenItsHostRouteLeaves() throws {
    let tracker = ScreenTracker(clock: ManualClock())
    shellWithTabAndSheet(tracker)
    tracker.isRecording = true
    XCTAssertEqual(tracker.navigatorIds.count, 4)

    // The sheet is swiped down: both of its screens disappear.
    tracker.disappeared(instanceId: "sheetDetail")
    tracker.disappeared(instanceId: "sheetRoot")
    let facts = tracker.takeFacts().map { $0.decodedInput }
    XCTAssertEqual(facts.count, 1, "the emptied sheet navigator sends nothing")
    XCTAssertEqual(facts.first?["kind"] as? String, "pop")
    XCTAssertEqual(facts.first?["navigatorId"] as? String, "swiftui-screens/tabA")
    XCTAssertEqual((facts.first?["route"] as? [String: Any])?["name"] as? String, "Details")
    XCTAssertNil(tracker.entries(of: "swiftui-screens/sheetNav"), "forgotten")
    XCTAssertEqual(tracker.visibleTop?.name, "Details")

    // Home is revealed: Details leaves and nothing it hosted remains; Home's own navigator stays.
    tracker.appeared(instanceId: "home", name: "Home", scope: scope("tabA", hostedBy: "shell"))
    XCTAssertEqual(tracker.takeFacts().first?.decodedInput["kind"] as? String, "pop")
    XCTAssertNotNil(tracker.entries(of: "swiftui-screens/homeInner"), "its host is on the stack again, now on top")
    XCTAssertEqual(tracker.visibleTop?.name, "Pane")

    // A screen pushed on the root covers Shell: what Shell hosts stays.
    tracker.appeared(instanceId: "other", name: "Other")
    tracker.settle()
    XCTAssertEqual(tracker.navigatorIds.count, 3, "a covered host keeps its navigators")
    XCTAssertEqual(tracker.visibleTop?.name, "Other")
    tracker.disappeared(instanceId: "other")
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "Pane")

    // Shell leaves the root: tabA goes, and homeInner with its parent.
    tracker.disappeared(instanceId: "shell")
    tracker.settle()
    XCTAssertEqual(tracker.navigatorIds, [root])
    XCTAssertNil(tracker.visibleTop)
  }

  func testNavigatorsGoWithTheirPoppedHostAndTheirParent() {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.appeared(instanceId: "home", name: "Home")
    tracker.settle()
    let tabs = scope("tabs", hostedBy: "detail")
    tracker.appeared(instanceId: "detail", name: "Detail")
    tracker.appeared(instanceId: "t1", name: "T1", scope: tabs)
    tracker.appeared(instanceId: "t2", name: "T2", scope: scope("deeper", in: tabs, hostedBy: "t1"))
    tracker.settle()
    XCTAssertEqual(tracker.navigatorIds, [root, "swiftui-screens/deeper", "swiftui-screens/tabs"])
    XCTAssertEqual(tracker.visibleTop?.name, "T2")

    tracker.appeared(instanceId: "home", name: "Home")
    tracker.settle()
    XCTAssertEqual(tracker.navigatorIds, [root], "Detail was popped: everything it hosted is forgotten")
    XCTAssertEqual(tracker.visibleTop?.name, "Home")
  }

  func testScreensUnderACoveredHostDisappearingChangeNothing() {
    let tracker = ScreenTracker(clock: ManualClock())
    let pane = scope("pane", hostedBy: "home")
    tracker.appeared(instanceId: "home", name: "Home")
    tracker.appeared(instanceId: "p1", name: "P1", scope: pane)
    tracker.appeared(instanceId: "d1", name: "D1", scope: scope("deep", in: pane, hostedBy: "p1"))
    tracker.settle()
    tracker.isRecording = true

    // Pushing Details covers Home; SwiftUI calls onDisappear for everything under it.
    tracker.appeared(instanceId: "details", name: "Details")
    tracker.disappeared(instanceId: "home")
    tracker.disappeared(instanceId: "p1")
    tracker.disappeared(instanceId: "d1")
    let facts = tracker.takeFacts().map { $0.decodedInput }
    XCTAssertEqual(facts.map { $0["kind"] as? String }, ["push"], "only the push on the root")
    XCTAssertEqual(tracker.entries(of: "swiftui-screens/pane")?.map { $0.name }, ["P1"])
    XCTAssertEqual(tracker.entries(of: "swiftui-screens/deep")?.map { $0.name }, ["D1"])
    XCTAssertEqual(tracker.visibleTop?.name, "Details")

    // Back to Home: its screens reappear on top of their stacks, which is no change.
    tracker.disappeared(instanceId: "details")
    tracker.appeared(instanceId: "home", name: "Home")
    tracker.appeared(instanceId: "p1", name: "P1", scope: pane)
    tracker.appeared(instanceId: "d1", name: "D1", scope: scope("deep", in: pane, hostedBy: "p1"))
    let back = tracker.takeFacts().map { $0.decodedInput }
    XCTAssertEqual(back.map { $0["kind"] as? String }, ["pop"])
    XCTAssertEqual(back.first?["navigatorId"] as? String, root)
    XCTAssertEqual(tracker.visibleTop?.name, "D1")
  }

  func testAnEmptiedNavigatorIsForgotten() {
    let tracker = ScreenTracker(clock: ManualClock())
    let tab = scope("tab", hostedBy: nil)
    tracker.appeared(instanceId: "a", name: "A", scope: tab)
    tracker.settle()
    XCTAssertEqual(tracker.navigatorIds, [root, "swiftui-screens/tab"])
    XCTAssertEqual(tracker.visibleTop?.name, "A", "a navigator with no host screen is under the root")
    tracker.disappeared(instanceId: "a")
    tracker.settle()
    XCTAssertEqual(tracker.navigatorIds, [root])
    XCTAssertNil(tracker.visibleTop)
  }

  func testAHostSeenAFrameLateDoesNotDropTheNavigator() {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.appeared(instanceId: "a", name: "A", scope: scope("inner", hostedBy: "shell"))
    tracker.settle()
    XCTAssertNotNil(tracker.entries(of: "swiftui-screens/inner"))
    XCTAssertNil(tracker.visibleTop, "not visible until its host is on the parent's stack")
    XCTAssertTrue(seeds(tracker).isEmpty, "never seeded while its host is unknown")
    tracker.appeared(instanceId: "shell", name: "Shell")
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "A")
    XCTAssertEqual(seeds(tracker).map { $0["navigatorId"] as? String }, [root, "swiftui-screens/inner"])
  }

  // MARK: Route key source

  func testTheVisibleTopFollowsTheVisibleChain() {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.appeared(instanceId: "shell", name: "Shell")
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "Shell")
    let left = scope("left", hostedBy: "shell")
    let right = scope("right", hostedBy: "shell")
    tracker.appeared(instanceId: "l1", name: "L1", scope: left)
    tracker.settle()
    tracker.appeared(instanceId: "r1", name: "R1", scope: right)
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "R1", "the most recently changed of two uncovered navigators")
    tracker.appeared(instanceId: "l2", name: "L2", scope: left)
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "L2")
    XCTAssertEqual(seeds(tracker).last?["navigatorId"] as? String, "swiftui-screens/left", "the seeds end on the same route")

    // A screen pushed on the root covers Shell and what it hosts.
    tracker.appeared(instanceId: "settings", name: "Settings")
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "Settings")
    XCTAssertEqual(seeds(tracker).map { $0["navigatorId"] as? String }, ["swiftui-screens/left", "swiftui-screens/right", root])
  }
}
