#if canImport(UIKit)
import UIKit

/// The Tugboat SwiftUI SDK (native SDK note section 3).
///
/// ```swift
/// final class AppDelegate: NSObject, UIApplicationDelegate {
///   func application(
///     _ application: UIApplication,
///     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
///   ) -> Bool {
///     Tugboat.start(TugboatConfig(
///       collector: .init(baseURL: url, apiKey: key),
///       app: .init(name: name, version: version, buildNumber: build, appId: bundleId, installationId: installId),
///       enabled: true))  // or leave it dormant and call `Tugboat.activate(activationRequestId:)` later
///     return true
///   }
/// }
/// ```
///
/// Mark screens with `.tugboatScreen("Checkout")` and controls with
/// `.tugboatTag("checkout")`. Forward the app's own events with
/// `eventHook(source:parameterPolicy:)` and its network calls with
/// `beginNetworkCall(method:route:)`.
///
/// Activation follows Flutter's `TugboatReplay`: `TugboatConfig.enabled` is
/// false by default, so `start` leaves Tugboat dormant (nothing installed or
/// recorded) until `activate(activationRequestId:)`; `deactivate()` returns
/// it to dormant. `lifecycleState`, `isActivated`, and `activationRequestId`
/// read where it is.
///
/// - Call `start` once, from `application(_:didFinishLaunchingWithOptions:)`
///   (a SwiftUI app adds an `@UIApplicationDelegateAdaptor`). After `stop`,
///   a new `start` begins again.
/// - Every method may be called from any thread; the work runs on the main
///   thread in call order. `activate`, `deactivate`, and `stop` change the
///   lifecycle state on the calling thread, before they return.
/// - Nothing here throws or traps into the app. A failure is logged
///   (subsystem `com.gettugboat.sdk`) and capture stops; the app keeps
///   running.
public enum Tugboat {
  /// Any thread.
  static let activation = ActivationState()

  // Main thread only.
  private static var sessionEpoch = 0
  private static var userId: String?
  private static var traitsInput: String?
  static let driver = ActivationDriver<TugboatRuntime>(
    state: activation,
    begin: { config, activationRequestId in beginSession(config: config, activationRequestId: activationRequestId) },
    open: { EvidenceChannel.shared.open($0.evidenceSink) },
    end: { runtime in
      EvidenceChannel.shared.close()
      runtime.stop()
    })

  /// `TUGBOAT_LAUNCH` / `TUGBOAT_HEALTH` (tests replace it); main thread.
  static var launchCorrelation = LaunchCorrelation(lifecycle: launchReading)
  /// The Device Farm launch inputs (tests replace it); main thread.
  static var launchOptions: () -> LaunchOptions? = { LaunchOptions.fromProcessInfo() }

  /// What the launch lines report now: the lifecycle, the request, and the
  /// running session's start (`dormant` once its engine host stopped);
  /// main thread.
  static func launchReading() -> LaunchCorrelation.Reading {
    LaunchCorrelation.Reading.of(
      activation.current, session: driver.session.map { ($0.sessionWallUs, $0.isHostRunning) })
  }

  /// The running session's runtime; main thread.
  static var runtime: TugboatRuntime? {
    driver.session
  }

  /// True while a session runs; main thread.
  static var isRunning: Bool {
    driver.session != nil
  }

  /// Where the capture lifecycle is; any thread. `starting` also after an
  /// `activate` made before `start`, until `start` runs it. A session that
  /// could not start (a configuration `start` refused, or the engine
  /// unavailable) leaves `dormant` with the request kept: the same
  /// `activate` tries again.
  public static var lifecycleState: TugboatLifecycleState {
    activation.current.state
  }

  /// True while a session requested by `activate` is starting or active
  /// (Flutter's `isActivated`: an activation id is set and the state is not
  /// `dormant`); false for a session started by `TugboatConfig.enabled`
  /// alone. Any thread.
  public static var isActivated: Bool {
    activation.current.isActivated
  }

  /// The id of the last `activate` until `deactivate` or `stop`, as given
  /// (a blank id is kept here but left off `session.start`); any thread. It
  /// stays set while `dormant` after a session failed to start, so the same
  /// `activate` retries.
  public static var activationRequestId: String? {
    activation.current.activationRequestId
  }

  /// Stores the configuration and, when `config.enabled` is true or an
  /// `activate` came first, starts a session. With `enabled` false (the
  /// default) Tugboat stays dormant: no engine, observers, method exchange,
  /// threads, or network until `activate`.
  ///
  /// Idempotent: while a configuration is stored (until `stop`), later calls
  /// are ignored. Refuses the configuration (and logs which field) when a
  /// field the collector requires on `session_start` is missing, for example
  /// a blank `App.version` or `App.buildNumber`.
  public static func start(_ config: TugboatConfig) {
    onMain {
      guard driver.config == nil else {
        HostLog.warning("Tugboat is already started")
        return
      }
      let missing = TugboatRuntime.missingFields(config)
      guard missing.isEmpty else {
        HostLog.error("Tugboat not started: required session_start fields are missing: \(missing)")
        // An `activate` made before this `start` is kept, as for a failed
        // session start, but is not left `starting`.
        activation.markFailed(activation.current.requestEpoch)
        return
      }
      if OutboxPolicy.wipeAtStart(config) {
        outbox?.wipe()
      }
      _ = driver.configure(config)
      launchCorrelation.startIfNeeded(parsed: launchOptions())
    }
  }

  /// Starts capture for `activationRequestId`, which `session.start`
  /// carries (omitted when blank), as Flutter's `TugboatReplay.activate`.
  ///
  /// - Dormant: a session starts.
  /// - The same id while starting or active: nothing happens.
  /// - A different id while active: the state goes to `starting` with the
  ///   new id at once; the current session ends (`session_end`) and a new
  ///   one, with a new `sessionEpoch`, starts for the new id.
  /// - Before `start` (or after `stop`): remembered and applied by the next
  ///   `start`, even when that configuration has `enabled` false.
  ///
  /// Each new id starts a new engine. The previous session's engine
  /// delivers its last events and `session_end` in the background and is
  /// disposed within about 25 s (sooner when the collector answers), so
  /// changing ids many times a second keeps that many engines draining.
  public static func activate(activationRequestId: String) {
    guard activation.activate(activationRequestId) else { return }
    onMain { driver.reconcile() }
  }

  /// Returns Tugboat to dormant, as Flutter's `TugboatReplay.deactivate`.
  /// Coded events and network calls stop being recorded before this
  /// returns, on the calling thread; then the session ends on the main
  /// thread as in `stop` (`session_end`, delivered in the background). The
  /// state is `stopping` until `session.end` is posted, then `dormant`. A
  /// configuration with `enabled` true does not start again until the next
  /// `activate`. Does nothing while dormant with no activation.
  ///
  /// The configuration, user id, and traits are kept. The hosting-controller
  /// method exchange, once installed, stays installed and records nothing.
  public static func deactivate() {
    guard activation.deactivate(fence: { EvidenceChannel.shared.close() }) else { return }
    onMain { driver.reconcile() }
  }

  /// The runtime user id stamped on later events; nil clears it. Kept
  /// across dormant periods, `stop`, and `start`, and sent to every new
  /// session.
  public static func setUserId(_ id: String?) {
    onMain {
      userId = id
      runtime?.setUserId(id)
    }
  }

  /// Replaces the traits bag (JSON values: strings, numbers, booleans,
  /// `NSNull`, arrays, dictionaries with string keys). Kept across dormant
  /// periods, `stop`, and `start`, and sent to every new session. A bag JSON
  /// cannot carry (NaN, infinities, other types) is ignored and logged.
  public static func setTraits(_ traits: [String: Any]) {
    // Encoded now: the caller may change its values after this returns.
    guard let input = SessionMessages.traitsInput(traits) else {
      HostLog.warning("Tugboat.setTraits ignored: the traits are not valid JSON values")
      return
    }
    onMain {
      traitsInput = input
      runtime?.setTraits(input)
    }
  }

  /// Ends the session and forgets the configuration, the activation request,
  /// and the `deactivate` override; a later `start` begins again, and an
  /// `activate` after `stop` is remembered for it. The session's last
  /// events and `session_end` are delivered in the background before the
  /// engine is disposed (at most about 25 s when the collector is
  /// unreachable). Evidence stops before this returns.
  ///
  /// `stop()` is not Flutter's `TugboatReplay.disabled`: there is no switch
  /// that makes `activate` ignored. The user id and traits are kept. The
  /// hosting-controller method exchange, once installed, stays installed
  /// and records nothing.
  public static func stop() {
    let stops = activation.reset(fence: { EvidenceChannel.shared.close() })
    LaunchCorrelation.cancelHealth()
    onMain { driver.stop(through: stops) }
  }

  /// Deletes every collector request kept on disk by
  /// `TugboatConfig.durableOutbox` and not yet delivered (masked frames and
  /// event, lifecycle bodies), from this and earlier launches. Requests
  /// already sent are not recalled; ones the running session sends later
  /// are kept again. Any thread; the deletion runs in the background, after
  /// writes already queued. A `start` whose configuration has
  /// `durableOutbox` false does the same.
  public static func clearPendingData() {
    outbox?.wipe()
  }

  /// The process's durable outbox (tests replace it); nil when Application
  /// Support is unavailable.
  static var outbox: Outbox? = Outbox.shared

  /// A hook that records the app's own coded events (for example analytics
  /// events) as evidence:
  ///
  /// ```swift
  /// let events = Tugboat.eventHook(source: "analytics", parameterPolicy: .allowList(["method"]))
  /// events.record("USER_LOGIN", parameters: ["method": "email"])
  /// ```
  ///
  /// The hook can be made before `start` and kept across sessions and
  /// dormant periods: each `record` goes to the session running then, and
  /// records nothing while none runs. `parameterPolicy` defaults
  /// to `.allowAll`, which keeps JSON-safe values within hard limits; use
  /// `.namesOnly` to keep keys only.
  public static func eventHook(
    source: String? = nil, parameterPolicy: TugboatParameterPolicy = .allowAll
  ) -> TugboatEventHook {
    TugboatEventHook(source: source, policy: parameterPolicy, channel: .shared)
  }

  /// Begins observing one logical network call; finish it with `complete`
  /// or `fail` on the returned token:
  ///
  /// ```swift
  /// let call = Tugboat.beginNetworkCall(method: "GET", route: "/orders/123")
  /// call.complete(statusCode: 200)
  /// ```
  ///
  /// `route` is a path the app chooses (dynamic ids allowed), never a full
  /// URL: query strings, headers, and request bodies are never recorded,
  /// and the engine drops a route that is not a bounded absolute path. A
  /// nil or empty route, or a call while no session runs (dormant, not
  /// started, deactivated, or stopped), gives a token that records nothing.
  public static func beginNetworkCall(method: String, route: String?) -> TugboatNetworkCall {
    TugboatNetworkCall.begin(method: method, route: route, channel: .shared)
  }

  /// Main thread: a new engine and `session.start`, then the kept user id
  /// and traits.
  private static func beginSession(config: TugboatConfig, activationRequestId: String?) -> TugboatRuntime? {
    guard
      let started = TugboatRuntime.start(
        config: config, sessionEpoch: sessionEpoch, activationRequestId: activationRequestId)
    else { return nil }
    sessionEpoch += 1
    // A new engine starts without a user id, so only a set one is sent.
    if let userId = userId {
      started.setUserId(userId)
    }
    if let traitsInput = traitsInput {
      started.setTraits(traitsInput)
    }
    return started
  }

  private static func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }
}
#endif
