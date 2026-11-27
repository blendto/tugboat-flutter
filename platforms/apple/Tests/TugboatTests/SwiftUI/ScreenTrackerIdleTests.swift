import XCTest

@testable import Tugboat

/// `.tugboatScreen` callbacks while no session records (Tugboat dormant or
/// deactivated): only the navigators' current state is kept, and the next
/// session's `session_start` seed still names the visible screen.
final class ScreenTrackerIdleTests: XCTestCase {
  /// Hops the tracker scheduled and the test has not run yet.
  private var pendingHops: [() -> Void] = []

  private func idleTracker() -> ScreenTracker {
    ScreenTracker(clock: ManualClock(), scheduleIdleSettle: { [unowned self] in self.pendingHops.append($0) })
  }

  /// One main-queue turn: the hops scheduled so far run.
  private func turn() {
    let hops = pendingHops
    pendingHops.removeAll()
    hops.forEach { $0() }
  }

  private func seedNames(_ tracker: ScreenTracker) -> [[String]] {
    tracker.sessionStartFacts(at: ManualClock().now()).map { fact in
      ((fact.decodedInput["routes"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }
  }

  /// 10 000 detail screens shown and dismissed, one per frame, with no
  /// session: the queue stays at one frame's callbacks and the seed is Home.
  func testDormantCallbacksKeepOnlyTheCurrentState() {
    let tracker = idleTracker()
    tracker.appeared(instanceId: "home", name: "Home")
    turn()
    var largest = 0
    for cycle in 0..<10_000 {
      let id = "detail-\(cycle)"
      tracker.appeared(instanceId: id, name: "Detail")
      turn()
      tracker.disappeared(instanceId: id)
      largest = max(largest, tracker.queuedCount)
      turn()
    }
    XCTAssertLessThanOrEqual(largest, 2)
    XCTAssertEqual(tracker.queuedCount, 0)
    XCTAssertLessThanOrEqual(pendingHops.count, 1, "one coalesced hop at most")
    XCTAssertEqual(tracker.entries(of: ScreenTracker.navigatorId)?.map { $0.name }, ["Home"])
    // A later session (`activate`) seeds the visible screen.
    tracker.beginSession()
    XCTAssertEqual(seedNames(tracker), [["Home"]])
  }

  /// When the main queue does not turn, the queue is still capped.
  func testTheIdleQueueIsCappedWithoutAMainTurn() {
    let tracker = idleTracker()
    tracker.appeared(instanceId: "home", name: "Home")
    for cycle in 0..<10_000 {
      tracker.appeared(instanceId: "detail-\(cycle)", name: "Detail")
      tracker.disappeared(instanceId: "detail-\(cycle)")
      XCTAssertLessThan(tracker.queuedCount, ScreenTracker.maxIdleQueue)
    }
    XCTAssertEqual(pendingHops.count, 1, "the hop is scheduled once until it runs")
  }

  /// A sheet with its own navigator, opened and torn down repeatedly while
  /// idle: its engine id is not re-incarnated (`#2`, `#3`, …) forever.
  func testIdleNavigatorIdsAreReleased() {
    let tracker = idleTracker()
    tracker.appeared(instanceId: "home", name: "Home")
    turn()
    let sheet = NavigatorScope.root.hosted(by: "home").nested("sheet")
    for cycle in 0..<50 {
      tracker.appeared(instanceId: "s-\(cycle)", name: "Sheet", scope: sheet)
      turn()
      tracker.disappeared(instanceId: "s-\(cycle)")
      turn()
    }
    tracker.appeared(instanceId: "s-last", name: "Sheet", scope: sheet)
    turn()
    XCTAssertEqual(tracker.engineNavigatorId(of: sheet.navigatorId), "swiftui-screens/sheet")
  }

  /// While recording nothing changes: callbacks wait for the frame.
  func testRecordingTrackersStillSettleOnTheFrame() {
    let tracker = idleTracker()
    tracker.isRecording = true
    tracker.appeared(instanceId: "home", name: "Home")
    tracker.appeared(instanceId: "detail", name: "Detail")
    XCTAssertEqual(tracker.queuedCount, 2)
    XCTAssertTrue(pendingHops.isEmpty)
    XCTAssertEqual(tracker.takeFacts().count, 2)
  }
}
