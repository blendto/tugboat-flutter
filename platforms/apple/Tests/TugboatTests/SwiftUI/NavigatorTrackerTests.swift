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
    let middle = outer.nested("middle")
    XCTAssertEqual(middle.nested("outer"), middle, "nor its own ancestor")
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

  func testSessionStartSeedsEveryNavigatorWithTheVisibleChainLast() throws {
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
    let tabASeed = try XCTUnwrap(seeds.dropFirst(2).first, "fewer than three seeds")
    let sheetRoute = (tabASeed["routes"] as? [[String: Any]])?.last
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

  // MARK: Tabs (silent switches) and activity

  /// Root `[Shell]`; `tabA` and `tabB` hosted by Shell. `tabA` gets
  /// `aScreens`, each push covering (and disappearing) the one below.
  private func shellWithTwoTabs(_ tracker: ScreenTracker, aScreens: [String]) -> (tabA: NavigatorScope, tabB: NavigatorScope) {
    let tabA = scope("tabA", hostedBy: "shell")
    let tabB = scope("tabB", hostedBy: "shell")
    tracker.appeared(instanceId: "shell", name: "Shell")
    var below: String?
    for name in aScreens {
      // A push: the new screen appears and the one it covers disappears.
      tracker.appeared(instanceId: name, name: name, scope: tabA)
      below.map { tracker.disappeared(instanceId: $0) }
      tracker.settle()
      below = name
    }
    return (tabA, tabB)
  }

  /// A tab switch: the incoming tab's top appears, the outgoing tab's top
  /// disappears, in one batch.
  private func switchTab(_ tracker: ScreenTracker, show shown: String, in scope: NavigatorScope, hide hidden: String) -> [[String: Any]] {
    tracker.appeared(instanceId: shown, name: shown, scope: scope)
    tracker.disappeared(instanceId: hidden)
    return tracker.takeFacts().map { $0.decodedInput }
  }

  func testATabSwitchIsSilentAndRouteKeysFollowTheShownTab() {
    let tracker = ScreenTracker(clock: ManualClock())
    let tabs = shellWithTwoTabs(tracker, aScreens: ["Home", "Details"])
    tracker.isRecording = true

    let first = switchTab(tracker, show: "Inbox", in: tabs.tabB, hide: "Details")
    XCTAssertEqual(first.map { $0["kind"] as? String }, ["push"], "tab B's first route only; tab A does not pop")
    XCTAssertEqual(first.first?["navigatorId"] as? String, "swiftui-screens/tabB")
    XCTAssertEqual(tracker.entries(of: "swiftui-screens/tabA")?.map { $0.name }, ["Home", "Details"], "the hidden tab keeps its stack")
    XCTAssertEqual(tracker.visibleTop?.name, "Inbox")

    let back = switchTab(tracker, show: "Details", in: tabs.tabA, hide: "Inbox")
    XCTAssertTrue(back.isEmpty, "no pop or push on the switch: \(back)")
    XCTAssertEqual(tracker.visibleTop?.name, "Details")
    let again = switchTab(tracker, show: "Inbox", in: tabs.tabB, hide: "Details")
    XCTAssertTrue(again.isEmpty, "no pop or push on the switch: \(again)")
    XCTAssertEqual(tracker.visibleTop?.name, "Inbox")
    XCTAssertEqual(tracker.entries(of: "swiftui-screens/tabA")?.map { $0.name }, ["Home", "Details"])
    XCTAssertEqual(tracker.entries(of: "swiftui-screens/tabB")?.map { $0.name }, ["Inbox"])
    XCTAssertEqual(seeds(tracker).last?["navigatorId"] as? String, "swiftui-screens/tabB", "the shown tab is seeded last")
  }

  func testASingleScreenTabRoundTripAddsNothing() {
    let tracker = ScreenTracker(clock: ManualClock())
    let tabs = shellWithTwoTabs(tracker, aScreens: ["Home"])
    _ = switchTab(tracker, show: "Inbox", in: tabs.tabB, hide: "Home")
    tracker.isRecording = true
    for _ in 0..<3 {
      XCTAssertTrue(switchTab(tracker, show: "Home", in: tabs.tabA, hide: "Inbox").isEmpty)
      XCTAssertEqual(tracker.visibleTop?.name, "Home")
      XCTAssertTrue(switchTab(tracker, show: "Inbox", in: tabs.tabB, hide: "Home").isEmpty)
      XCTAssertEqual(tracker.visibleTop?.name, "Inbox")
    }
    XCTAssertEqual(tracker.entries(of: "swiftui-screens/tabA")?.map { $0.name }, ["Home"])
    XCTAssertEqual(tracker.entries(of: "swiftui-screens/tabB")?.map { $0.name }, ["Inbox"])
    XCTAssertEqual(tracker.navigatorIds, [root, "swiftui-screens/tabA", "swiftui-screens/tabB"])
  }

  func testAPopFromADisappearanceIsNotActivity() {
    let tracker = ScreenTracker(clock: ManualClock())
    let left = scope("left", hostedBy: "shell")
    tracker.appeared(instanceId: "shell", name: "Shell")
    tracker.appeared(instanceId: "l1", name: "L1", scope: left)
    tracker.settle()
    tracker.appeared(instanceId: "l2", name: "L2", scope: left)
    tracker.settle()
    tracker.appeared(instanceId: "r1", name: "R1", scope: scope("right", hostedBy: "shell"))
    tracker.settle()
    tracker.isRecording = true
    // L2 leaves with no appearance in the batch: a real pop, but the shown
    // column is still the one that last appeared.
    tracker.disappeared(instanceId: "l2")
    let facts = tracker.takeFacts().map { $0.decodedInput }
    XCTAssertEqual(facts.map { $0["kind"] as? String }, ["pop"])
    XCTAssertEqual(facts.first?["navigatorId"] as? String, "swiftui-screens/left")
    XCTAssertEqual(tracker.visibleTop?.name, "R1")
    // The revealed screen's own appearance makes its navigator the shown one.
    tracker.appeared(instanceId: "l1", name: "L1", scope: left)
    XCTAssertTrue(tracker.takeFacts().isEmpty, "L1 is already the top")
    XCTAssertEqual(tracker.visibleTop?.name, "L1")
  }

  func testAHostlessNavigatorIsVisibleOnlyWithTheNewestAppearance() {
    let tracker = ScreenTracker(clock: ManualClock())
    // No screen around the tab's navigator; a sheet attached to the TabView is on the root.
    tracker.appeared(instanceId: "home", name: "Home", scope: scope("tabA", hostedBy: nil))
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "Home")
    tracker.appeared(instanceId: "paywall", name: "Paywall", overlayKind: .sheet)
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "Paywall", "the root's own appearance is newer")
    XCTAssertEqual(seeds(tracker).map { $0["navigatorId"] as? String }, ["swiftui-screens/tabA", root])
    tracker.appeared(instanceId: "detail", name: "Detail", scope: scope("tabA", hostedBy: nil))
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "Detail")
  }

  func testCoveredNavigatorsAreSeededInStackOrder() {
    let tracker = ScreenTracker(clock: ManualClock())
    for screen in ["a", "b", "c"] {
      tracker.appeared(instanceId: screen, name: screen.uppercased())
      tracker.settle()
    }
    // Named against key order: `z` is hosted by the lower route.
    tracker.appeared(instanceId: "z1", name: "Z1", scope: scope("z", hostedBy: "a"))
    tracker.appeared(instanceId: "y1", name: "Y1", scope: scope("y", hostedBy: "b"))
    tracker.settle()
    XCTAssertEqual(seeds(tracker).map { $0["navigatorId"] as? String }, ["swiftui-screens/z", "swiftui-screens/y", root])
    XCTAssertEqual(tracker.visibleTop?.name, "C")
  }

  // MARK: Sheet with its root inside its navigator (the documented pattern)

  /// `.sheet { NavigationStack { SheetRoot().tugboatScreen("SheetRoot",
  /// presentation: .sheet) }.tugboatNavigator("sheet") }`, attached inside
  /// the Details screen on the root.
  func testASheetWithItsRootInsideItsNavigator() throws {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.appeared(instanceId: "home", name: "Home")
    tracker.settle()
    tracker.appeared(instanceId: "details", name: "Details")
    tracker.settle()
    tracker.isRecording = true
    let sheet = scope("sheet", hostedBy: "details")

    tracker.appeared(instanceId: "sheetRoot", name: "SheetRoot", overlayKind: .sheet, scope: sheet)
    let opened = try XCTUnwrap(tracker.takeFacts().first, "the sheet root is pushed")
    XCTAssertEqual(
      opened.input.json,
      "{\"kind\":\"push\",\"navigatorId\":\"swiftui-screens/sheet\",\"parentNavigatorId\":\"swiftui-screens\",\"route\":{\"instanceId\":\"sheetRoot\",\"name\":\"SheetRoot\",\"type\":\"TugboatScreen\",\"overlayKind\":\"sheet\",\"transitionMs\":0}}",
      "the first route on the child navigator is the sheet root"
    )
    XCTAssertEqual(tracker.visibleTop?.name, "SheetRoot")

    // A push inside the sheet: same navigator as the visible route, so the tap's claim holds.
    tracker.appeared(instanceId: "sheetDetail", name: "SheetDetail", scope: sheet)
    tracker.disappeared(instanceId: "sheetRoot")
    let pushed = tracker.takeFacts().map { $0.decodedInput }
    XCTAssertEqual(pushed.map { $0["kind"] as? String }, ["push"])
    XCTAssertEqual(pushed.first?["navigatorId"] as? String, "swiftui-screens/sheet")
    XCTAssertEqual((pushed.first?["departing"] as? [String: Any])?["name"] as? String, "SheetRoot")
    XCTAssertEqual((pushed.first?["route"] as? [String: Any])?["transitionMs"] as? Int, 350)

    // Back to the sheet root: a pop on the sheet's navigator.
    tracker.appeared(instanceId: "sheetRoot", name: "SheetRoot", overlayKind: .sheet, scope: sheet)
    tracker.disappeared(instanceId: "sheetDetail")
    let popped = tracker.takeFacts().map { $0.decodedInput }
    XCTAssertEqual(popped.map { $0["kind"] as? String }, ["pop"])
    XCTAssertEqual(popped.first?["navigatorId"] as? String, "swiftui-screens/sheet")
    XCTAssertEqual((popped.first?["route"] as? [String: Any])?["name"] as? String, "SheetRoot")
    XCTAssertEqual(tracker.visibleTop?.name, "SheetRoot")

    // Dismissed: the emptied navigator is forgotten without a fact; route keys return to Details.
    tracker.disappeared(instanceId: "sheetRoot")
    XCTAssertTrue(tracker.takeFacts().isEmpty)
    XCTAssertNil(tracker.entries(of: "swiftui-screens/sheet"))
    XCTAssertEqual(tracker.visibleTop?.name, "Details")
  }

  /// Review 2 B1: a sheet with its own stack, dismissed from below its
  /// root. Only the top (`SheetDetail`) gets `onDisappear`; `SheetRoot`
  /// already disappeared when SheetDetail was pushed. The sheet is
  /// attached inside the Details screen (host Details) or outside it (no
  /// host); both tear down.
  func testDismissingAStackedSheetFromDepthTearsItDown() throws {
    for host in ["details", nil] as [String?] {
      let tracker = ScreenTracker(clock: ManualClock())
      tracker.appeared(instanceId: "home", name: "Home")
      tracker.settle()
      tracker.appeared(instanceId: "details", name: "Details")
      tracker.disappeared(instanceId: "home")
      tracker.settle()
      tracker.isRecording = true
      let sheet = scope("sheet", hostedBy: host)
      tracker.appeared(instanceId: "sheetRoot", name: "SheetRoot", overlayKind: .sheet, scope: sheet)
      tracker.settle()
      tracker.appeared(instanceId: "sheetDetail", name: "SheetDetail", scope: sheet)
      tracker.disappeared(instanceId: "sheetRoot")
      XCTAssertEqual(tracker.takeFacts().map { $0.decodedInput["kind"] as? String }, ["push", "push"], "host \(String(describing: host))")
      XCTAssertEqual(tracker.visibleTop?.name, "SheetDetail")

      tracker.disappeared(instanceId: "sheetDetail")
      let dismissed = tracker.takeFacts().map { $0.decodedInput }
      XCTAssertTrue(dismissed.isEmpty, "no false pop to the gone SheetRoot: \(dismissed)")
      XCTAssertNil(tracker.entries(of: "swiftui-screens/sheet"), "the sheet's navigator is forgotten")
      XCTAssertEqual(tracker.visibleTop?.name, "Details", "route keys are back on the presenter")
      XCTAssertEqual(seeds(tracker).map { $0["navigatorId"] as? String }, [root])

      // Reopened: a new SheetRoot instance is the first route again.
      tracker.appeared(instanceId: "sheetRoot2", name: "SheetRoot", overlayKind: .sheet, scope: sheet)
      let reopened = try XCTUnwrap(tracker.takeFacts().first?.decodedInput, "the reopened sheet is pushed")
      XCTAssertEqual(reopened["kind"] as? String, "push")
      XCTAssertNil(reopened["departing"], "a first route")
      XCTAssertEqual((reopened["route"] as? [String: Any])?["transitionMs"] as? Int, 0)
      XCTAssertEqual(tracker.entries(of: "swiftui-screens/sheet")?.map { $0.instanceId }, ["sheetRoot2"])
    }
  }

  func testAStacklessSheetOnANestedNavigatorPopsOnDismissal() throws {
    let tracker = ScreenTracker(clock: ManualClock())
    let tabA = scope("tabA", hostedBy: "shell")
    tracker.appeared(instanceId: "shell", name: "Shell")
    tracker.appeared(instanceId: "home", name: "Home", scope: tabA)
    tracker.settle()
    tracker.isRecording = true
    // The presenter stays on screen under a sheet.
    tracker.appeared(instanceId: "quick", name: "Quick", overlayKind: .sheet, scope: tabA)
    _ = tracker.takeFacts()
    tracker.disappeared(instanceId: "quick")
    let pop = try XCTUnwrap(tracker.takeFacts().first?.decodedInput, "the dismissal pops")
    XCTAssertEqual(pop["kind"] as? String, "pop")
    XCTAssertEqual(pop["navigatorId"] as? String, "swiftui-screens/tabA")
    XCTAssertEqual((pop["route"] as? [String: Any])?["name"] as? String, "Home")
    XCTAssertEqual(tracker.visibleTop?.name, "Home")
  }

  /// Review 2 M1: a collapsed `NavigationSplitView` (iPhone, compact width).
  /// Select is a push of the detail column, back its pop, with the same
  /// pair of callbacks in one frame as a tab switch. Sibling navigators are
  /// treated as mutually exclusive, so the back is silent (a documented
  /// limit), but the detail stack never grows: the next selection rebuilds
  /// it as a first route.
  func testACollapsedSplitViewsDetailStackDoesNotGrow() throws {
    let tracker = ScreenTracker(clock: ManualClock())
    let sidebar = scope("sidebar", hostedBy: nil)
    let detail = scope("detail", hostedBy: nil)
    tracker.appeared(instanceId: "list", name: "List", scope: sidebar)
    tracker.settle()
    tracker.isRecording = true
    for index in 1...3 {
      tracker.appeared(instanceId: "item\(index)", name: "Item", scope: detail)
      tracker.disappeared(instanceId: "list")
      let selected = tracker.takeFacts().map { $0.decodedInput }
      XCTAssertEqual(selected.map { $0["kind"] as? String }, ["push"], "select \(index)")
      XCTAssertNil(selected.first?["departing"], "select \(index) is the detail's first route")
      XCTAssertEqual(tracker.entries(of: "swiftui-screens/detail")?.map { $0.instanceId }, ["item\(index)"])
      XCTAssertEqual(tracker.visibleTop?.instanceId, "item\(index)")

      tracker.appeared(instanceId: "list", name: "List", scope: sidebar)
      tracker.disappeared(instanceId: "item\(index)")
      XCTAssertTrue(tracker.takeFacts().isEmpty, "back is silent (documented limit)")
      XCTAssertEqual(tracker.entries(of: "swiftui-screens/detail")?.count, 1, "the detail stack does not grow")
      XCTAssertEqual(tracker.entries(of: "swiftui-screens/sidebar")?.map { $0.name }, ["List"])
      XCTAssertEqual(tracker.visibleTop?.name, "List", "route keys follow the shown column")
    }
  }

  func testACollapsedSplitViewWithOnlyTheDetailOptedIn() {
    let tracker = ScreenTracker(clock: ManualClock())
    let detail = scope("detail", hostedBy: nil)
    tracker.appeared(instanceId: "list", name: "List")
    tracker.settle()
    tracker.isRecording = true
    for index in 1...3 {
      tracker.appeared(instanceId: "item\(index)", name: "Item", scope: detail)
      tracker.disappeared(instanceId: "list")
      _ = tracker.takeFacts()
      XCTAssertEqual(tracker.entries(of: "swiftui-screens/detail")?.map { $0.instanceId }, ["item\(index)"])
      tracker.appeared(instanceId: "list", name: "List")
      tracker.disappeared(instanceId: "item\(index)")
      _ = tracker.takeFacts()
      XCTAssertNil(tracker.entries(of: "swiftui-screens/detail"), "back tears the detail navigator down")
      XCTAssertEqual(tracker.visibleTop?.name, "List")
    }
  }

  /// Side by side (regular width): the detail column's screen goes away
  /// with nothing appearing. Its navigator is kept (the sidebar is on
  /// screen), but an off-screen top is never the visible route, even
  /// though it appeared last.
  func testAKeptNavigatorWithItsTopOffScreenIsNotVisible() {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.appeared(instanceId: "list", name: "List", scope: scope("sidebar", hostedBy: nil))
    tracker.settle()
    tracker.appeared(instanceId: "item", name: "Item", scope: scope("detail", hostedBy: nil))
    tracker.settle()
    XCTAssertEqual(tracker.visibleTop?.name, "Item")
    tracker.disappeared(instanceId: "item")
    tracker.settle()
    XCTAssertEqual(tracker.entries(of: "swiftui-screens/detail")?.map { $0.name }, ["Item"], "kept: the sidebar is on screen")
    XCTAssertEqual(tracker.visibleTop?.name, "List")
    XCTAssertEqual(seeds(tracker).last?["navigatorId"] as? String, "swiftui-screens/sidebar")
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
