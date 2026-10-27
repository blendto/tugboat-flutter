#if canImport(UIKit)
import SwiftUI
import TugboatSessionEngine
import UIKit
import XCTest

@testable import Tugboat

/// Every engine a session opens, with what the SDK submitted to it. Each
/// session gets a real engine (`EngineBridge`), so `session.start` is really
/// applied; the recorder only watches.
final class EngineRecorder {
  struct Message {
    let engine: Int
    let type: String
    let input: [String: Any]
    let ok: Bool
  }

  private final class Transport: EngineTransport {
    let inner: EngineBridge
    let engine: Int
    let recorder: EngineRecorder

    init(inner: EngineBridge, engine: Int, recorder: EngineRecorder) {
      self.inner = inner
      self.engine = engine
      self.recorder = recorder
    }

    func submit(_ message: Data) -> EngineResponse {
      let response = inner.submit(message)
      recorder.record(engine: engine, json: jsonObject(String(decoding: message, as: UTF8.self)), ok: response.status == TB_SESSION_OK)
      return response
    }

    func close() {
      inner.close()
    }
  }

  private let state = Locked<(opened: Int, messages: [Message])>((0, []))

  var opened: Int { state.current.opened }
  var messages: [Message] { state.current.messages }

  /// `TugboatRuntime.openTransport`.
  func open() -> EngineTransport? {
    guard let inner = EngineBridge.open() else { return nil }
    let engine = state.withLock { (state: inout (opened: Int, messages: [Message])) -> Int in
      state.opened += 1
      return state.opened
    }
    return Transport(inner: inner, engine: engine, recorder: self)
  }

  /// Inputs of `type`, batches unwrapped, in submit order.
  func inputs(_ type: String, engine: Int? = nil) -> [[String: Any]] {
    messages.filter { $0.type == type && (engine == nil || $0.engine == engine) }.map { $0.input }
  }

  private func record(engine: Int, json: [String: Any], ok: Bool) {
    var found: [Message] = []
    if json["type"] as? String == "batch", let nested = json["messages"] as? [[String: Any]] {
      for message in nested {
        found.append(
          Message(engine: engine, type: message["type"] as? String ?? "", input: message["input"] as? [String: Any] ?? [:], ok: ok))
      }
    } else {
      found.append(
        Message(engine: engine, type: json["type"] as? String ?? "", input: json["input"] as? [String: Any] ?? [:], ok: ok))
    }
    state.withLock { $0.messages.append(contentsOf: found) }
  }
}

/// `Tugboat.activate` / `deactivate` and `TugboatConfig.enabled` on the
/// facade, with real engines: Flutter's activation contract (D1).
final class TugboatActivationTests: XCTestCase {
  private var recorder = EngineRecorder()
  private var states: [TugboatLifecycleState] = []
  private var previousOpen: (() -> EngineTransport?)?

  override func setUp() {
    super.setUp()
    previousOpen = TugboatRuntime.openTransport
    let recorder = self.recorder
    TugboatRuntime.openTransport = { recorder.open() }
    Tugboat.activation.onChange = { [weak self] snapshot in
      DispatchQueue.main.async { self?.states.append(snapshot.state) }
    }
  }

  override func tearDown() {
    Tugboat.activation.onChange = nil
    Tugboat.stop()
    drainMain()
    if let previousOpen = previousOpen {
      TugboatRuntime.openTransport = previousOpen
    }
    super.tearDown()
  }

  /// `enabled` is left at the configuration's default unless true.
  private func config(enabled: Bool = false, trackHostingControllers: Bool = false) -> TugboatConfig {
    var config = TugboatConfig(
      collector: .init(baseURL: URL(string: "http://127.0.0.1:9") ?? URL(fileURLWithPath: "/"), apiKey: "key"),
      app: .init(name: "Tests", version: "1.0", buildNumber: "1", appId: "com.tugboat.tests", installationId: "i-1"),
      trackHostingControllers: trackHostingControllers)
    if enabled {
      config.enabled = true
    }
    return config
  }

  /// Lets queued main-thread work run.
  private func drainMain() {
    let drained = expectation(description: "main drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  /// Spins the main run loop until `condition` holds (engine submits are
  /// async).
  @discardableResult
  private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { return false }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return true
  }

  /// Runs `work` on another thread while the main thread is blocked, so
  /// nothing queued on main can run before `work` returns.
  private func onBackground(_ work: @escaping () -> Void) {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      work()
      done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
  }

  func testTheDefaultConfigurationIsDormant() {
    let installAttempts = ViewControllerAppearance.installAttempts
    Tugboat.start(config(trackHostingControllers: true))
    drainMain()
    XCTAssertEqual(recorder.opened, 0, "no engine")
    XCTAssertFalse(Tugboat.isRunning)
    XCTAssertNil(Tugboat.runtime, "no runtime, so no lifecycle, locale, window, or KVO observers")
    XCTAssertEqual(Tugboat.lifecycleState, .dormant)
    XCTAssertFalse(Tugboat.isActivated)
    XCTAssertNil(Tugboat.activationRequestId)
    XCTAssertNil(EvidenceChannel.shared.admit())
    XCTAssertFalse(Tugboat.beginNetworkCall(method: "GET", route: "/a").isRecording)
    XCTAssertFalse(ScreenTracker.shared.isRecording)
    XCTAssertFalse(HostingControllerTracker.shared.isRecording)
    XCTAssertEqual(
      ViewControllerAppearance.installAttempts, installAttempts, "a dormant start does not even try to install the exchange")
    Tugboat.activate(activationRequestId: "act-1")
    drainMain()
    XCTAssertGreaterThan(ViewControllerAppearance.installAttempts, installAttempts, "the seam counts a session start")
  }

  func testActivateFromDormantPutsTheIdOnSessionStart() {
    Tugboat.start(config())
    Tugboat.activate(activationRequestId: "act-1")
    XCTAssertTrue(eventually { !self.recorder.inputs(SessionMessages.sessionStart).isEmpty })
    let start = recorder.inputs(SessionMessages.sessionStart)
    XCTAssertEqual(start.count, 1)
    XCTAssertEqual(start.first?["activationRequestId"] as? String, "act-1")
    XCTAssertEqual(recorder.messages.first { $0.type == SessionMessages.sessionStart }?.ok, true, "the engine applied it")
    XCTAssertEqual(Tugboat.lifecycleState, .active)
    XCTAssertTrue(Tugboat.isActivated)
    XCTAssertEqual(Tugboat.activationRequestId, "act-1")
    XCTAssertNotNil(EvidenceChannel.shared.admit())
    XCTAssertEqual(Tugboat.runtime?.observesLocale, true)
  }

  func testTheSameIdIsIdempotent() {
    Tugboat.start(config())
    Tugboat.activate(activationRequestId: "act-1")
    Tugboat.activate(activationRequestId: "act-1")
    onBackground { Tugboat.activate(activationRequestId: "act-1") }
    drainMain()
    XCTAssertTrue(eventually { !self.recorder.inputs(SessionMessages.sessionStart).isEmpty })
    XCTAssertEqual(recorder.opened, 1)
    XCTAssertEqual(recorder.inputs(SessionMessages.sessionStart).count, 1)
    XCTAssertTrue(recorder.inputs(SessionMessages.sessionEnd).isEmpty)
  }

  func testANewIdEndsTheSessionAndStartsANewEpochWithoutStopping() {
    Tugboat.start(config())
    Tugboat.activate(activationRequestId: "act-1")
    drainMain()
    states.removeAll()
    Tugboat.activate(activationRequestId: "act-2")
    XCTAssertEqual(Tugboat.activationRequestId, "act-2", "visible at once")
    drainMain()
    XCTAssertTrue(eventually { self.recorder.inputs(SessionMessages.sessionStart, engine: 2).count == 1 })
    XCTAssertTrue(eventually { self.recorder.inputs(SessionMessages.sessionEnd, engine: 1).count == 1 })
    XCTAssertEqual(recorder.inputs(SessionMessages.sessionEnd, engine: 1).first?["reason"] as? String, "session_end")
    let first = recorder.inputs(SessionMessages.sessionStart, engine: 1).first
    let second = recorder.inputs(SessionMessages.sessionStart, engine: 2).first
    XCTAssertEqual(second?["activationRequestId"] as? String, "act-2")
    XCTAssertGreaterThan(second?["sessionEpoch"] as? Int ?? -1, first?["sessionEpoch"] as? Int ?? Int.max)
    XCTAssertEqual(states, [.starting, .active])
    XCTAssertFalse(states.contains(.stopping))
    XCTAssertEqual(Tugboat.lifecycleState, .active)
  }

  /// `deactivate()` off the main thread: a call begun in the same turn,
  /// before main runs anything, records nothing.
  func testDeactivateFencesEvidenceBeforeMainRuns() {
    Tugboat.start(config(enabled: true))
    drainMain()
    XCTAssertNotNil(EvidenceChannel.shared.admit())
    let hook = Tugboat.eventHook(source: "tests")
    var admitted: Int?
    var recording = true
    var stateAfter: TugboatLifecycleState?
    let mainRan = Locked(false)
    onBackground {
      DispatchQueue.main.async { mainRan.withLock { $0 = true } }
      Tugboat.deactivate()
      stateAfter = Tugboat.lifecycleState
      admitted = EvidenceChannel.shared.admit()
      let call = Tugboat.beginNetworkCall(method: "GET", route: "/orders/1")
      recording = call.isRecording
      call.complete(statusCode: 200)
      hook.record("AFTER_DEACTIVATE")
    }
    XCTAssertFalse(mainRan.current, "the checks ran before main got a turn")
    XCTAssertEqual(stateAfter, .stopping)
    XCTAssertNil(admitted)
    XCTAssertFalse(recording)
    drainMain()
    XCTAssertTrue(eventually { !self.recorder.inputs(SessionMessages.sessionEnd).isEmpty })
    XCTAssertEqual(Tugboat.lifecycleState, .dormant)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertTrue(recorder.inputs(EvidenceMessages.networkCall).isEmpty)
    XCTAssertTrue(recorder.inputs(EvidenceMessages.externalEvent).isEmpty)
  }

  func testAnEnabledConfigurationStaysDownAfterDeactivateUntilActivate() {
    Tugboat.start(config(enabled: true))
    drainMain()
    XCTAssertEqual(recorder.opened, 1)
    XCTAssertNil(recorder.inputs(SessionMessages.sessionStart).first?["activationRequestId"])
    XCTAssertFalse(Tugboat.isActivated)
    Tugboat.deactivate()
    drainMain()
    Tugboat.start(config(enabled: true))
    drainMain()
    XCTAssertEqual(recorder.opened, 1)
    XCTAssertEqual(Tugboat.lifecycleState, .dormant)
    Tugboat.activate(activationRequestId: "act-1")
    drainMain()
    XCTAssertEqual(recorder.opened, 2)
    XCTAssertTrue(eventually { self.recorder.inputs(SessionMessages.sessionStart, engine: 2).count == 1 })
    XCTAssertEqual(recorder.inputs(SessionMessages.sessionStart, engine: 2).first?["activationRequestId"] as? String, "act-1")
  }

  func testActivateBeforeStartIsAppliedByStart() {
    Tugboat.activate(activationRequestId: "early")
    XCTAssertEqual(Tugboat.lifecycleState, .starting)
    drainMain()
    XCTAssertEqual(recorder.opened, 0)
    Tugboat.start(config(enabled: false))
    drainMain()
    XCTAssertTrue(eventually { !self.recorder.inputs(SessionMessages.sessionStart).isEmpty })
    XCTAssertEqual(recorder.inputs(SessionMessages.sessionStart).first?["activationRequestId"] as? String, "early")
    XCTAssertEqual(Tugboat.lifecycleState, .active)
  }

  func testStopClearsTheActivation() {
    Tugboat.start(config())
    Tugboat.activate(activationRequestId: "act-1")
    Tugboat.stop()
    XCTAssertNil(Tugboat.activationRequestId)
    drainMain()
    XCTAssertEqual(Tugboat.lifecycleState, .dormant)
    XCTAssertTrue(eventually { !self.recorder.inputs(SessionMessages.sessionEnd).isEmpty })
    Tugboat.start(config())
    drainMain()
    XCTAssertEqual(recorder.opened, 1, "no activation carried over")
    XCTAssertEqual(Tugboat.lifecycleState, .dormant)
  }

  func testTheLocaleObserverLivesOnlyWithTheSession() {
    Tugboat.start(config())
    NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    Tugboat.activate(activationRequestId: "act-1")
    drainMain()
    let runtime = Tugboat.runtime
    XCTAssertEqual(runtime?.observesLocale, true, "added at session start")
    Tugboat.deactivate()
    drainMain()
    XCTAssertEqual(runtime?.observesLocale, false, "removed at session end")
    XCTAssertNil(Tugboat.runtime)
  }

  /// State-keeping APIs are not gated: a user id set and a hook made while
  /// dormant feed the session `activate` starts.
  func testTheUserIdAndHooksAreKeptAcrossDormant() {
    Tugboat.start(config())
    Tugboat.setUserId("user-1")
    let hook = Tugboat.eventHook(source: "tests", parameterPolicy: .namesOnly)
    hook.record("WHILE_DORMANT")
    Tugboat.activate(activationRequestId: "act-1")
    drainMain()
    hook.record("AFTER_ACTIVATE")
    drainMain()
    XCTAssertTrue(eventually { !self.recorder.inputs(EvidenceMessages.externalEvent).isEmpty })
    XCTAssertEqual(recorder.inputs(SessionMessages.identitySet).first?["userId"] as? String, "user-1")
    XCTAssertEqual(recorder.inputs(EvidenceMessages.externalEvent).compactMap { $0["name"] as? String }, ["AFTER_ACTIVATE"])
  }

  /// The appearance exchange stays installed after `deactivate`, still
  /// forwards to the original implementation, and records nothing.
  func testTheAppearanceExchangeStaysInertAfterDeactivate() {
    // Fresh trackers: a `.tugboatScreen` seen by an earlier test would
    // silence hosting-controller tracking and hide a recording bug.
    ScreenTracker.shared.reset()
    HostingControllerTracker.shared.reset()
    defer {
      ScreenTracker.shared.reset()
      HostingControllerTracker.shared.reset()
    }
    Tugboat.start(config(enabled: true, trackHostingControllers: true))
    drainMain()
    XCTAssertTrue(ViewControllerAppearance.isInstalled)
    Tugboat.deactivate()
    drainMain()
    XCTAssertTrue(ViewControllerAppearance.isInstalled, "never exchanged back")
    XCTAssertFalse(HostingControllerTracker.shared.isRecording)
    let previous = ViewControllerAppearance.observer
    var forwarded = 0
    ViewControllerAppearance.observer = { controller, appeared in
      forwarded += 1
      previous?(controller, appeared)
    }
    defer { ViewControllerAppearance.observer = previous }
    let probe = AppearanceProbe()
    let window = HostedWindow(controller: probe)
    defer { window.close() }
    let hosting = HostedWindow(Text("Hosted"))
    defer { hosting.close() }
    XCTAssertTrue(window.wait { probe.appeared })
    XCTAssertTrue(hosting.wait { forwarded >= 2 }, "the exchanged methods still run")
    XCTAssertTrue(HostingControllerTracker.shared.takeFacts().isEmpty, "and record nothing")
    let hostingFacts = { self.recorder.inputs(FactTypes.navigation).filter { $0["navigatorId"] as? String == HostingControllerTracker.navigatorId } }
    let before = hostingFacts().count
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    // Only navigation facts count: the stopped engine still drains (timers, HTTP results).
    XCTAssertEqual(hostingFacts().count, before)
  }

  /// Item 12: a hosting controller already on screen when the first session
  /// starts is in that session's `session_start` seed.
  func testAHostingControllerOnScreenBeforeActivateIsSeeded() {
    ScreenTracker.shared.reset()
    HostingControllerTracker.shared.reset()
    defer {
      ScreenTracker.shared.reset()
      HostingControllerTracker.shared.reset()
    }
    let hosting = HostedWindow(Text("Already on screen"))
    defer { hosting.close() }
    hosting.window.makeKeyAndVisible()
    hosting.settle()
    // The SDK takes the key windows of the connected scenes; the CI test
    // host does not list its windows there, so the test names its window.
    let previousKeyWindows = SwiftUIAdapter.keyWindows
    SwiftUIAdapter.keyWindows = { [hosting.window] }
    defer { SwiftUIAdapter.keyWindows = previousKeyWindows }
    let expected = [hosting.hosting.map(RouteKey.hostingKey) ?? "?"]
    let diagnostics = "key window: \(hosting.window.isKeyWindow), screen seen: \(ScreenTracker.shared.hasSeenScreen)"
    Tugboat.start(config(trackHostingControllers: true))
    Tugboat.activate(activationRequestId: "act-1")
    drainMain()
    // The tracker's seed, then what reached the engine (the adapter's batch
    // is flushed at the latest when the session ends).
    let trackerSeed = HostingControllerTracker.shared.sessionStartFact(at: HostTime(monoUs: 1, wallUs: 1))?.decodedInput
    XCTAssertEqual(
      ((trackerSeed?["routes"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }, expected, diagnostics)
    Tugboat.deactivate()
    drainMain()
    let seed: () -> [String: Any]? = {
      self.recorder.inputs(FactTypes.navigation).first {
        $0["kind"] as? String == "session_start" && $0["navigatorId"] as? String == HostingControllerTracker.navigatorId
      }
    }
    XCTAssertTrue(eventually { seed() != nil }, diagnostics)
    let routes = (seed()?["routes"] as? [[String: Any]]) ?? []
    XCTAssertEqual(routes.compactMap { $0["name"] as? String }, expected, diagnostics)
  }

  /// Item 12's walk on its own, on a fresh tracker: the root, a child that
  /// covers the window, and not a small embedded host.
  func testAdoptingControllersOnScreenWalksTheHierarchy() {
    let tracker = HostingControllerTracker(screens: ScreenTracker())
    let container = UIViewController()
    let window = HostedWindow(controller: container)
    defer { window.close() }
    let full = UIHostingController(rootView: Text("Full"))
    let small = UIHostingController(rootView: AnyView(Text("Badge")))
    for (child, frame) in [(full as UIViewController, window.window.bounds), (small, CGRect(x: 0, y: 0, width: 40, height: 40))] {
      container.addChild(child)
      child.view.frame = frame
      container.view.addSubview(child.view)
      child.didMove(toParent: container)
    }
    window.settle()
    tracker.adoptControllersOnScreen(in: [window.window])
    let seed = tracker.sessionStartFact(at: HostTime(monoUs: 1, wallUs: 1))?.decodedInput
    let routes = (seed?["routes"] as? [[String: Any]]) ?? []
    XCTAssertEqual(routes.compactMap { $0["name"] as? String }, [RouteKey.hostingKey(full)])
  }

  /// m1: HEALTH reads the running session when it prints.
  func testTheLaunchReadingFollowsTheRunningSession() {
    Tugboat.start(config())
    XCTAssertNil(Tugboat.launchReading().sessionWallUs)
    Tugboat.activate(activationRequestId: "act-1")
    drainMain()
    let first = Tugboat.runtime?.sessionWallUs
    Tugboat.activate(activationRequestId: "act-2")
    drainMain()
    let reading = Tugboat.launchReading()
    XCTAssertEqual(reading.activationRequestId, "act-2")
    XCTAssertEqual(reading.state, .active)
    XCTAssertNotNil(reading.sessionWallUs)
    XCTAssertEqual(reading.sessionWallUs, Tugboat.runtime?.sessionWallUs)
    XCTAssertNotEqual(reading.sessionWallUs, first)
    Tugboat.deactivate()
    drainMain()
    let dormant = Tugboat.launchReading()
    XCTAssertEqual(dormant.state, .dormant)
    XCTAssertNil(dormant.sessionWallUs)
    XCTAssertNil(dormant.activationRequestId)
  }

  /// m2: with launch inputs, a dormant `start` logs LAUNCH at once and a
  /// dormant HEALTH later.
  func testADormantStartLogsLaunchAndHealth() {
    let previousCorrelation = Tugboat.launchCorrelation
    let previousOptions = Tugboat.launchOptions
    defer {
      Tugboat.launchCorrelation = previousCorrelation
      Tugboat.launchOptions = previousOptions
      LaunchCorrelation.resetForTests()
    }
    LaunchCorrelation.resetForTests()
    var lines: [String] = []
    var health: (() -> Void)?
    Tugboat.launchCorrelation = LaunchCorrelation(
      lifecycle: Tugboat.launchReading,
      schedule: { _, block in
        health = block
        return DispatchWorkItem {}
      },
      emit: { lines.append($0) })
    Tugboat.launchOptions = { LaunchOptions(emitSceneInventory: true, acceptActionContext: false, automationRunId: nil) }
    Tugboat.start(config())
    drainMain()
    XCTAssertEqual(lines.count, 1)
    XCTAssertTrue(lines.first?.hasPrefix("TUGBOAT_LAUNCH {") ?? false)
    XCTAssertFalse(lines.first?.contains("captureSessionId") ?? true)
    health?()
    XCTAssertEqual(lines.last, "TUGBOAT_HEALTH {\"lifecycle\":\"dormant\"}")
  }

  /// Smoke test: `stop()` and `activate` from one background thread, in
  /// each call order, before main runs: never `active` without a session.
  /// One thread cannot make main run the work in the reverse order (the
  /// actual race); the Linux `ActivationTests` race tests cover that.
  func testStopAndActivateCalledFromOneBackgroundThread() {
    Tugboat.start(config(enabled: true))
    drainMain()
    XCTAssertTrue(Tugboat.isRunning)
    onBackground {
      Tugboat.activate(activationRequestId: "act-1")
      Tugboat.stop()
    }
    drainMain()
    XCTAssertFalse(Tugboat.isRunning)
    XCTAssertEqual(Tugboat.lifecycleState, .dormant)
    XCTAssertNil(Tugboat.activationRequestId)

    Tugboat.start(config(enabled: true))
    drainMain()
    XCTAssertTrue(Tugboat.isRunning)
    onBackground {
      Tugboat.stop()
      Tugboat.activate(activationRequestId: "act-2")
    }
    drainMain()
    XCTAssertFalse(Tugboat.isRunning, "stop forgot the configuration; the activate waits for the next start")
    XCTAssertEqual(Tugboat.lifecycleState, .starting)
    XCTAssertEqual(Tugboat.activationRequestId, "act-2")
    Tugboat.start(config())
    drainMain()
    XCTAssertEqual(Tugboat.lifecycleState, .active)
    XCTAssertTrue(eventually {
      self.recorder.inputs(SessionMessages.sessionStart).last?["activationRequestId"] as? String == "act-2"
    })
  }

  /// An `activate` before a `start` whose configuration is refused: dormant,
  /// the request kept, never stuck at `starting`.
  func testARefusedStartAfterActivateIsDormantWithTheRequestKept() {
    Tugboat.activate(activationRequestId: "early")
    var refused = config()
    refused.app.version = " "
    Tugboat.start(refused)
    drainMain()
    XCTAssertEqual(Tugboat.lifecycleState, .dormant)
    XCTAssertEqual(Tugboat.activationRequestId, "early")
    XCTAssertEqual(recorder.opened, 0)
    Tugboat.start(config())
    Tugboat.activate(activationRequestId: "early")
    drainMain()
    XCTAssertEqual(Tugboat.lifecycleState, .active)
    XCTAssertTrue(eventually { !self.recorder.inputs(SessionMessages.sessionStart).isEmpty })
    XCTAssertEqual(recorder.inputs(SessionMessages.sessionStart).first?["activationRequestId"] as? String, "early")
  }
}

/// A controller whose `viewDidAppear` override must still reach `super`
/// through the exchange.
private final class AppearanceProbe: UIViewController {
  private(set) var appeared = false

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    appeared = true
  }
}
#endif
