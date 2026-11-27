import Foundation

/// Maps a request to the bounded route path recorded for it, such as
/// `/orders/{id}` or `/orders/123`: never a URL, query, or fragment. Return
/// nil or an empty route (or throw) to record nothing for that request. The
/// result is trimmed as Dart's `String.trim` does.
public typealias TugboatRouteResolver = (URLRequest) throws -> String?

#if canImport(UIKit)
extension Tugboat {
  /// A `URLSession` that records each task as `network_call` evidence, for
  /// the app to use in place of its own session:
  ///
  /// ```swift
  /// let session = Tugboat.instrumentedSession(configuration: .default, delegate: appDelegate) { request in
  ///   request.url.map { router.route(for: $0) }   // for example "/orders/123"
  /// }
  /// ```
  ///
  /// The session is made from the app's own `configuration`, `delegate`,
  /// and `delegateQueue`, unchanged. Its delegate is a proxy that passes
  /// every callback the app's delegate implements to it unchanged (auth
  /// challenges, redirects, response dispositions, data, downloads, streams,
  /// background events) and implements no others, apart from observing
  /// data, metrics, and completion. No `URLProtocol`, swizzling, or second
  /// session is involved, so caching, cookies, credentials, metrics, and
  /// background sessions behave as before. `session.delegate` is the proxy:
  /// keep your own reference to your delegate.
  ///
  /// - One event per task, from its metrics or its completion: redirects
  ///   and URLSession's own authentication retries stay inside it. A retry
  ///   the app makes is a new task and a new event.
  /// - The duration is the task's own (from its metrics, `fetchStartDate`
  ///   to the end of `taskInterval`), placed before the host clock reading
  ///   at which the call is recorded.
  /// - Outcome: `URLError.cancelled` is `cancelled`, any other error
  ///   `network_error`, and a response `response` with its status code.
  /// - The error body (status 400 or more) is read only from the bytes a
  ///   delegate-based data task delivers to `didReceive data` (at most
  ///   65,537 are kept; the app's delegate gets every byte unchanged).
  ///   Tasks with a completion handler, `async` `data(for:)`, and download
  ///   tasks record no body: use `Tugboat.data(for:session:delegate:route:)`
  ///   for an `async` call with its error body.
  /// - `routeResolver` runs once per task, on the delegate queue, with the
  ///   task's `originalRequest`, only while Tugboat takes evidence.
  ///   Query strings, headers, request bodies and error text are never read.
  /// - `URLSession.shared` and sessions the app makes itself are not
  ///   observed. A background session is observed the same way and never
  ///   altered (tasks finishing after a relaunch may predate the session
  ///   and are then dropped). Stream and WebSocket tasks are not recorded.
  ///
  /// Nothing here throws or traps into the app, and the app's requests and
  /// responses are identical with and without it.
  public static func instrumentedSession(
    configuration: URLSessionConfiguration = .default,
    delegate: URLSessionDelegate? = nil,
    delegateQueue: OperationQueue? = nil,
    routeResolver: @escaping TugboatRouteResolver
  ) -> URLSession {
    let proxy = InstrumentedSessionDelegate(
      wrapping: delegate, recorder: NetworkTaskRecorder(routeResolver: routeResolver))
    return URLSession(configuration: configuration, delegate: proxy, delegateQueue: delegateQueue)
  }

  /// `session.data(for: request, delegate: delegate)`, recorded as one
  /// `network_call` with its error body: the `async` counterpart of an
  /// instrumented session, for any session (`URLSession.shared` included).
  ///
  /// ```swift
  /// let (data, response) = try await Tugboat.data(for: request, route: "/orders/123")
  /// ```
  ///
  /// Returns and throws exactly what URLSession does; `data` is untouched.
  /// The call runs from this function's start to its return on the host
  /// clock. For a status of 400 or more the body is read from the returned
  /// `data` by the same rule as an instrumented session (JSON when the
  /// response says so and the body is at most 64 KiB, otherwise text).
  /// `route` is trimmed; nil or empty records nothing. `delegate`, if
  /// given, receives exactly the callbacks it would receive from URLSession
  /// directly. On an instrumented session the call is recorded once, here.
  public static func data(
    for request: URLRequest,
    session: URLSession = .shared,
    delegate: URLSessionTaskDelegate? = nil,
    route: String?
  ) async throws -> (Data, URLResponse) {
    let call = TugboatNetworkCall.begin(
      method: NetworkRoute.method(request), route: NetworkRoute.trimmed(route), channel: .shared)
    let taskDelegate = RecordedByHelperTaskDelegate(wrapping: delegate)
    let result: (Data, URLResponse)
    do {
      result = try await session.data(for: request, delegate: taskDelegate)
    } catch {
      NetworkOutcome.finish(call, response: nil, error: error) { nil }
      throw error
    }
    NetworkOutcome.finish(call, response: result.1, error: nil) {
      HTTPErrorBody.body(bytes: result.0, contentType: NetworkOutcome.contentType(of: result.1))
    }
    return result
  }
}
#endif
