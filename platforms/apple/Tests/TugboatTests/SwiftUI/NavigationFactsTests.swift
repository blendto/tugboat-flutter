import XCTest

@testable import Tugboat

/// Navigation facts in the stateful-engine.md 8.1 shape from the screen
/// stack and `ScreenTracker`.
final class NavigationFactsTests: XCTestCase {
  private let home = RouteEntry(instanceId: "s-1", name: "Home", type: "TugboatScreen")
  private let detail = RouteEntry(instanceId: "s-2", name: "Detail", type: "TugboatScreen")
  private let sheet = RouteEntry(instanceId: "s-3", name: "Sheet", type: "TugboatScreen")

  func testPushCoverAndPopByReappearance() {
    var stack = ScreenStack(navigatorId: "nav")
    XCTAssertEqual(stack.appeared(home), NavigationChange(kind: .push, navigatorId: "nav", route: home, departing: nil))
    XCTAssertEqual(stack.appeared(detail), NavigationChange(kind: .push, navigatorId: "nav", route: detail, departing: home))
    XCTAssertNil(stack.disappeared(instanceId: home.instanceId), "a covered screen stays on the stack")
    XCTAssertEqual(stack.appeared(home), NavigationChange(kind: .pop, navigatorId: "nav", route: home, departing: detail))
    XCTAssertNil(stack.disappeared(instanceId: detail.instanceId), "already popped")
    XCTAssertEqual(stack.entries, [home])
    XCTAssertNil(stack.appeared(home), "appearing again on top is no change")
  }

  func testTheTopDisappearingPopsToTheScreenBelow() {
    var stack = ScreenStack(navigatorId: "nav")
    _ = stack.appeared(home)
    _ = stack.appeared(sheet)
    XCTAssertEqual(stack.disappeared(instanceId: sheet.instanceId), NavigationChange(kind: .pop, navigatorId: "nav", route: home, departing: sheet))
    XCTAssertNil(stack.disappeared(instanceId: home.instanceId), "nothing left to reveal")
    XCTAssertNil(stack.top)
  }

  func testTheStackIsBounded() {
    var stack = ScreenStack(navigatorId: "nav")
    for index in 0..<(ScreenStack.maxEntries + 10) {
      _ = stack.appeared(RouteEntry(instanceId: "s-\(index)", name: nil, type: "T"))
    }
    XCTAssertEqual(stack.entries.count, ScreenStack.maxEntries)
  }

  func testFactJSONMatchesTheEngineShape() throws {
    let at = HostTime(monoUs: 5, wallUs: 6)
    let fact = NavigationChange(kind: .push, navigatorId: "swiftui-screens", route: detail, departing: home).fact(at: at)
    XCTAssertEqual(fact.type, "navigation")
    XCTAssertEqual(fact.at, at)
    XCTAssertEqual(
      fact.input.json,
      "{\"kind\":\"push\",\"navigatorId\":\"swiftui-screens\",\"route\":{\"instanceId\":\"s-2\",\"name\":\"Detail\",\"type\":\"TugboatScreen\",\"overlayKind\":\"page\",\"transitionMs\":350},\"departing\":{\"instanceId\":\"s-1\",\"name\":\"Home\",\"type\":\"TugboatScreen\"}}"
    )
    let first = NavigationChange(kind: .push, navigatorId: "n", route: home, departing: nil).fact(at: at)
    let route = try XCTUnwrap(first.decodedInput["route"] as? [String: Any])
    XCTAssertEqual(route["transitionMs"] as? Int, 0, "the first route has no transition")
  }

  func testTrackerAppliesAppearancesFirstWithinAFrame() {
    let clock = ManualClock()
    let tracker = ScreenTracker(clock: clock)
    tracker.isRecording = true
    var requested = 0
    tracker.onEvent = { requested += 1 }

    tracker.appeared(instanceId: "a", name: "Home")
    XCTAssertEqual(tracker.takeFacts().count, 1)
    clock.advance(ms: 10)
    // SwiftUI may report the old screen's disappear before the new one's appear.
    tracker.disappeared(instanceId: "a")
    clock.advance(ms: 5)
    tracker.appeared(instanceId: "b", name: "Detail")
    let facts = tracker.takeFacts()
    XCTAssertEqual(requested, 3)
    XCTAssertEqual(facts.count, 1, "a push, not a pop then a push")
    XCTAssertEqual(facts.first?.decodedInput["kind"] as? String, "push")
    XCTAssertEqual((facts.first?.decodedInput["departing"] as? [String: Any])?["name"] as? String, "Home")
    XCTAssertEqual(facts.first?.at, clock.now(), "the appear callback's time")
    XCTAssertEqual(tracker.top?.name, "Detail")
  }

  func testTrackerKeepsTheStackButNoFactsWhileNotRecording() {
    let tracker = ScreenTracker(clock: ManualClock())
    tracker.appeared(instanceId: "a", name: "Home")
    XCTAssertTrue(tracker.takeFacts().isEmpty)
    XCTAssertEqual(tracker.top?.name, "Home", "route keys work before the adapter starts")
    XCTAssertTrue(tracker.hasSeenScreen)
  }

  func testInstanceIdsAreUnique() {
    XCTAssertNotEqual(ScreenTracker.newInstanceId(), ScreenTracker.newInstanceId())
  }
}
