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
///       app: .init(name: name, version: version, buildNumber: build, appId: bundleId, installationId: installId)))
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
/// - Call `start` once, from `application(_:didFinishLaunchingWithOptions:)`
///   (a SwiftUI app adds an `@UIApplicationDelegateAdaptor`). After `stop`,
///   a new `start` begins a new session.
/// - Every method may be called from any thread; the work runs on the main
///   thread in call order.
/// - Nothing here throws or traps into the app. A failure is logged
///   (subsystem `com.gettugboat.sdk`) and capture stops; the app keeps
///   running.
public enum Tugboat {
  // Main thread only.
  private static var runtime: TugboatRuntime?
  private static var sessionEpoch = 0
  private static var userId: String?
  private static var traitsInput: String?

  /// True between a successful `start` and `stop`; main thread.
  static var isRunning: Bool {
    runtime != nil
  }

  /// Starts capture and a session. Idempotent: while started, later calls
  /// are ignored. Refuses to start (and logs which field) when a field the
  /// collector requires on `session_start` is missing, for example a blank
  /// `App.version` or `App.buildNumber`.
  public static func start(_ config: TugboatConfig) {
    onMain {
      guard runtime == nil else {
        HostLog.warning("Tugboat is already started")
        return
      }
      guard let started = TugboatRuntime.start(config: config, sessionEpoch: sessionEpoch) else { return }
      sessionEpoch += 1
      runtime = started
      EvidenceChannel.shared.open(started.evidenceSink)
      // A new engine starts without a user id, so only a set one is sent.
      if let userId = userId {
        started.setUserId(userId)
      }
      if let traitsInput = traitsInput {
        started.setTraits(traitsInput)
      }
    }
  }

  /// The runtime user id stamped on later events; nil clears it. Kept
  /// across `stop` and `start`.
  public static func setUserId(_ id: String?) {
    onMain {
      userId = id
      runtime?.setUserId(id)
    }
  }

  /// Replaces the traits bag (JSON values: strings, numbers, booleans,
  /// `NSNull`, arrays, dictionaries with string keys). Kept across `stop`
  /// and `start`. A bag JSON cannot carry (NaN, infinities, other types) is
  /// ignored and logged.
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

  /// Ends the session and stops capture. The session's last events and
  /// `session_end` are delivered in the background before the engine is
  /// disposed (at most about 25 s when the collector is unreachable).
  public static func stop() {
    onMain {
      EvidenceChannel.shared.close()
      runtime?.stop()
      runtime = nil
    }
  }

  /// A hook that records the app's own coded events (for example analytics
  /// events) as evidence:
  ///
  /// ```swift
  /// let events = Tugboat.eventHook(source: "analytics", parameterPolicy: .allowList(["method"]))
  /// events.record("USER_LOGIN", parameters: ["method": "email"])
  /// ```
  ///
  /// The hook can be made before `start` and kept across sessions: each
  /// `record` goes to the session running then. `parameterPolicy` defaults
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
  /// nil or empty route, or a call while Tugboat is not started, stopped,
  /// or disabled, gives a token that records nothing.
  public static func beginNetworkCall(method: String, route: String?) -> TugboatNetworkCall {
    TugboatNetworkCall.begin(method: method, route: route, channel: .shared)
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
