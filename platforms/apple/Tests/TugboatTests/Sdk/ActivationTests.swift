import Foundation
import XCTest

@testable import Tugboat

/// `ActivationState` and `ActivationDriver`: Flutter's activation contract
/// (`lifecycle.dart`, the activation gate) on native, with fake sessions.
/// The facade tests (`TugboatActivationTests`) run the same contract on a
/// real engine.
final class ActivationTests: XCTestCase {
  private final class FakeSession {
    let activationRequestId: String?
    var opened = false
    var ended = false

    init(activationRequestId: String?) {
      self.activationRequestId = activationRequestId
    }
  }

  private var state = ActivationState()
  private var begun: [FakeSession] = []
  private var states: [TugboatLifecycleState] = []
  private var failNextBegin = false
  private var duringBegin: (() -> Void)?
  private lazy var driver = ActivationDriver<FakeSession>(
    state: state,
    begin: { [unowned self] _, id in
      self.duringBegin?()
      if self.failNextBegin {
        self.failNextBegin = false
        return nil
      }
      let session = FakeSession(activationRequestId: id)
      self.begun.append(session)
      return session
    },
    open: { $0.opened = true },
    end: { $0.ended = true })

  /// The `index`th session begun, nil (not a crash) when there are fewer.
  private func at(_ index: Int) -> FakeSession? {
    index < begun.count ? begun[index] : nil
  }

  override func setUp() {
    super.setUp()
    state.onChange = { [unowned self] in self.states.append($0.state) }
  }

  private func config(enabled: Bool = false) -> TugboatConfig {
    TugboatConfig(
      collector: .init(baseURL: URL(fileURLWithPath: "/"), apiKey: "k"),
      app: .init(name: "n", version: "1", buildNumber: "1", appId: "a", installationId: "i"),
      enabled: enabled)
  }

  /// `Tugboat.activate` / `deactivate`: the state change on the calling
  /// thread, then the main-thread reconcile.
  private func activate(_ id: String) {
    if state.activate(id) { driver.reconcile() }
  }

  private var fenced = 0

  private func deactivate() {
    if state.deactivate(fence: { fenced += 1 }) { driver.reconcile() }
  }

  func testTheDefaultConfigurationIsDormant() {
    let defaults = TugboatConfig(
      collector: .init(baseURL: URL(fileURLWithPath: "/"), apiKey: "k"),
      app: .init(name: "n", version: "1", buildNumber: "1", appId: "a", installationId: "i"))
    XCTAssertFalse(defaults.enabled)
    XCTAssertTrue(driver.configure(defaults))
    XCTAssertTrue(begun.isEmpty, "no session, so no engine or observers")
    XCTAssertNil(driver.session)
    XCTAssertEqual(state.current.state, .dormant)
    XCTAssertFalse(state.current.isActivated)
    XCTAssertEqual(states, [])
  }

  func testAnEnabledConfigurationStartsASessionWithoutAnId() {
    _ = driver.configure(config(enabled: true))
    XCTAssertEqual(begun.count, 1)
    XCTAssertEqual(at(0).map { $0.activationRequestId }, .some(nil))
    XCTAssertEqual(at(0)?.opened, true)
    XCTAssertEqual(state.current.state, .active)
    XCTAssertFalse(state.current.isActivated, "Flutter: no activation id, not activated")
    XCTAssertEqual(states, [.starting, .active])
  }

  func testActivateFromDormantStartsASessionWithTheId() {
    _ = driver.configure(config())
    activate("run-1")
    XCTAssertEqual(begun.map { $0.activationRequestId }, ["run-1"])
    XCTAssertEqual(at(0)?.opened, true)
    XCTAssertEqual(state.current.state, .active)
    XCTAssertEqual(state.current.activationRequestId, "run-1")
    XCTAssertTrue(state.current.isActivated)
    XCTAssertEqual(states, [.starting, .active])
  }

  func testTheSameIdWhileActiveIsANoOp() {
    _ = driver.configure(config())
    activate("run-1")
    let epoch = state.current.requestEpoch
    XCTAssertFalse(state.activate("run-1"))
    activate("run-1")
    XCTAssertEqual(begun.count, 1)
    XCTAssertEqual(at(0)?.ended, false)
    XCTAssertEqual(state.current.requestEpoch, epoch)
  }

  func testTheSameIdWhileStartingIsANoOp() {
    XCTAssertTrue(state.activate("run-1"))
    XCTAssertEqual(state.current.state, .starting)
    XCTAssertFalse(state.activate("run-1"))
  }

  func testANewIdWhileActiveEndsTheSessionAndStartsAnotherWithoutStopping() {
    _ = driver.configure(config())
    activate("run-1")
    states.removeAll()
    XCTAssertTrue(state.activate("run-2"))
    XCTAssertEqual(state.current.state, .starting, "the new request is visible before main runs")
    XCTAssertEqual(state.current.activationRequestId, "run-2")
    driver.reconcile()
    XCTAssertEqual(begun.map { $0.activationRequestId }, ["run-1", "run-2"])
    XCTAssertEqual(at(0)?.ended, true, "the old session ends through the stop path")
    XCTAssertEqual(at(1)?.ended, false)
    XCTAssertEqual(at(1)?.opened, true)
    XCTAssertEqual(states, [.starting, .active])
    XCTAssertFalse(states.contains(.stopping))
  }

  func testActivatingAnEnabledSessionRestartsItWithTheId() {
    _ = driver.configure(config(enabled: true))
    activate("run-1")
    XCTAssertEqual(begun.map { $0.activationRequestId }, [nil, "run-1"])
    XCTAssertEqual(at(0)?.ended, true)
    XCTAssertEqual(state.current.state, .active)
  }

  func testDeactivateFencesOnTheCallingThreadThenEndsTheSession() {
    _ = driver.configure(config())
    activate("run-1")
    states.removeAll()
    XCTAssertTrue(state.deactivate(fence: { fenced += 1 }))
    XCTAssertEqual(fenced, 1, "the fence runs inside deactivate, before main")
    XCTAssertEqual(state.current.state, .stopping)
    XCTAssertNil(state.current.activationRequestId)
    XCTAssertEqual(at(0)?.ended, false, "the session ends on main")
    driver.reconcile()
    XCTAssertEqual(at(0)?.ended, true)
    XCTAssertNil(driver.session)
    XCTAssertEqual(state.current.state, .dormant)
    XCTAssertEqual(states, [.stopping, .dormant])
  }

  func testDeactivateWhileDormantWithoutAnIdDoesNothing() {
    _ = driver.configure(config())
    XCTAssertFalse(state.deactivate(fence: { fenced += 1 }))
    XCTAssertEqual(fenced, 0)
    XCTAssertEqual(state.current.requestEpoch, 0)
  }

  func testAnEnabledConfigurationStaysDownAfterDeactivateUntilActivate() {
    _ = driver.configure(config(enabled: true))
    deactivate()
    XCTAssertEqual(begun.count, 1)
    XCTAssertEqual(at(0)?.ended, true)
    driver.reconcile()
    XCTAssertEqual(begun.count, 1, "the override keeps it down")
    XCTAssertEqual(state.current.state, .dormant)
    activate("run-1")
    XCTAssertEqual(begun.map { $0.activationRequestId }, [nil, "run-1"])
    XCTAssertEqual(state.current.state, .active)
  }

  func testActivateBeforeStartIsAppliedByStart() {
    activate("early")
    XCTAssertTrue(begun.isEmpty)
    XCTAssertEqual(state.current.state, .starting)
    XCTAssertEqual(state.current.activationRequestId, "early")
    _ = driver.configure(config(enabled: false))
    XCTAssertEqual(begun.map { $0.activationRequestId }, ["early"])
    XCTAssertEqual(state.current.state, .active)
  }

  func testStopClearsTheActivationAndTheOverride() {
    _ = driver.configure(config())
    activate("run-1")
    state.reset(fence: { fenced += 1 })
    XCTAssertEqual(fenced, 1)
    XCTAssertEqual(state.current.state, .stopping)
    XCTAssertNil(state.current.activationRequestId)
    driver.stop()
    XCTAssertEqual(at(0)?.ended, true)
    XCTAssertNil(driver.config)
    XCTAssertEqual(state.current.state, .dormant)
    _ = driver.configure(config())
    XCTAssertEqual(begun.count, 1, "no activation is carried over")
    XCTAssertEqual(state.current.state, .dormant)

    // A deactivate override is cleared too.
    state.reset(fence: {})
    driver.stop()
    _ = driver.configure(config(enabled: true))
    XCTAssertEqual(begun.count, 2)
    deactivate()
    XCTAssertEqual(at(1)?.ended, true)
    state.reset(fence: {})
    driver.stop()
    _ = driver.configure(config(enabled: true))
    XCTAssertEqual(begun.count, 3, "enabled applies again after stop")
    XCTAssertEqual(at(2).map { $0.activationRequestId }, .some(nil))
    XCTAssertEqual(state.current.state, .active)
  }

  /// `stop()` then `activate` on another thread, before main runs either.
  func testActivateAfterStopIsRememberedForTheNextStart() {
    _ = driver.configure(config())
    activate("run-1")
    state.reset(fence: {})
    XCTAssertTrue(state.activate("run-2"))
    driver.stop()
    driver.reconcile()
    XCTAssertEqual(state.current.state, .starting, "the later activate wins over stop's dormant mark")
    XCTAssertEqual(begun.count, 1)
    _ = driver.configure(config())
    XCTAssertEqual(begun.map { $0.activationRequestId }, ["run-1", "run-2"])
    XCTAssertEqual(state.current.state, .active)
  }

  func testASecondConfigureIsIgnored() {
    XCTAssertTrue(driver.configure(config()))
    XCTAssertFalse(driver.configure(config(enabled: true)))
    XCTAssertTrue(begun.isEmpty)
  }

  /// A `deactivate` on another thread while main is starting the session:
  /// the session is never opened, and it ends in the same main turn.
  func testADeactivateDuringBeginKeepsTheSessionClosed() {
    _ = driver.configure(config())
    duringBegin = { [unowned self] in
      self.duringBegin = nil
      XCTAssertTrue(self.state.deactivate(fence: { self.fenced += 1 }))
    }
    activate("run-1")
    XCTAssertEqual(begun.count, 1)
    XCTAssertEqual(at(0)?.opened, false)
    XCTAssertEqual(at(0)?.ended, true, "ended before the deactivate's own reconcile runs")
    XCTAssertNil(driver.session)
    XCTAssertEqual(state.current.state, .dormant)
    driver.reconcile()
    XCTAssertEqual(begun.count, 1)
  }

  /// A new id on another thread while main is starting the session: the
  /// overtaken session is ended and the new one started in the same turn.
  func testANewIdDuringBeginIsAppliedInTheSameTurn() {
    _ = driver.configure(config())
    duringBegin = { [unowned self] in
      self.duringBegin = nil
      XCTAssertTrue(self.state.activate("run-2"))
    }
    activate("run-1")
    XCTAssertEqual(begun.map { $0.activationRequestId }, ["run-1", "run-2"])
    XCTAssertEqual(at(0)?.opened, false)
    XCTAssertEqual(at(0)?.ended, true)
    XCTAssertEqual(at(1)?.opened, true)
    XCTAssertEqual(state.current.state, .active)
    XCTAssertEqual(state.current.activationRequestId, "run-2")
  }

  /// `Tugboat.start` refusing its configuration after an `activate`: the
  /// request is kept, the state is `dormant` (not stuck at `starting`), and
  /// the same `activate` is accepted again.
  func testARefusedStartAfterActivateIsDormantWithTheRequestKept() {
    XCTAssertTrue(state.activate("early"))
    XCTAssertEqual(state.current.state, .starting)
    state.markFailed(state.current.requestEpoch)  // what the refused `start` does
    XCTAssertEqual(state.current.state, .dormant)
    XCTAssertEqual(state.current.activationRequestId, "early")
    XCTAssertFalse(state.current.isActivated)
    XCTAssertTrue(state.activate("early"), "the same activate retries")
    _ = driver.configure(config())
    XCTAssertEqual(begun.map { $0.activationRequestId }, ["early"])
    XCTAssertEqual(state.current.state, .active)
  }

  func testAFailedStartIsDormantAndTheSameActivateRetries() {
    _ = driver.configure(config())
    failNextBegin = true
    activate("run-1")
    XCTAssertTrue(begun.isEmpty)
    XCTAssertEqual(state.current.state, .dormant)
    XCTAssertFalse(state.current.isActivated)
    activate("run-1")
    XCTAssertEqual(begun.map { $0.activationRequestId }, ["run-1"])
    XCTAssertEqual(state.current.state, .active)
  }

  func testABlankIdStillActivates() {
    _ = driver.configure(config())
    activate("  ")
    XCTAssertEqual(begun.map { $0.activationRequestId }, ["  "])
    XCTAssertTrue(state.current.isActivated)
    XCTAssertNil(SessionMessages.normalizedSessionId("  "), "left off the wire")
  }

  func testAStaleReconcileChangesNothing() {
    _ = driver.configure(config())
    activate("run-1")
    driver.reconcile()
    driver.reconcile()
    XCTAssertEqual(begun.count, 1)
    XCTAssertEqual(at(0)?.ended, false)
  }
}
