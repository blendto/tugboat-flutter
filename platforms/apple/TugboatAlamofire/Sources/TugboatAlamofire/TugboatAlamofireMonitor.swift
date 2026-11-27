import Alamofire
import Foundation
@_spi(TugboatAdapters) import Tugboat

/// Records each logical Alamofire request as Tugboat `network_call`
/// evidence: the Alamofire counterpart of `tugboat_dio`'s
/// `TugboatDioInterceptor`. Pass it to the `Session`:
///
/// ```swift
/// let session = Session(
///   interceptor: authAndRetry,
///   eventMonitors: [TugboatAlamofireMonitor { request in router.route(for: request) }])
/// ```
///
/// - One event per `Request`, however many attempts it took: Alamofire's
///   retries (a `RequestRetrier`, `RetryPolicy`, `AuthenticationInterceptor`)
///   reuse the `Request`, and `attemptCount` is `retryCount + 1`. The call
///   begins when Alamofire makes the first attempt's `URLRequest` (after
///   adapters run, as Dio interceptors installed after auth see it) and
///   ends when the request finishes, on the host clock.
/// - Alamofire finishes a request before its response serializers run, so
///   a retry that a serializer asks for (for example an
///   `AuthenticationInterceptor` refresh after a 401 that was not
///   `validate()`d) is not part of the recorded call: the first finish is
///   recorded and later attempts are ignored. Use `validate()` so retries
///   are decided before the request finishes.
/// - Outcome, as `tugboat_dio` maps Dio's: a cancelled request (`cancel()`,
///   or `URLError.cancelled`) is `cancelled`; a request with an HTTP
///   response is `response` with its status code (validation and
///   serialization errors included); anything else (transport errors,
///   timeouts, adaptation or retry failures) is `network_error`.
/// - Error body, for a status of 400 or more on a `DataRequest`: from the
///   data Alamofire already holds, only its first 65,537 bytes, as JSON text
///   when it is complete (64 KiB or less) and the `Content-Type` is JSON,
///   otherwise as text. Download and stream requests record no body.
/// - `routeResolver` runs once per request, with the first attempt's
///   `URLRequest`, only while Tugboat takes evidence; nil, empty, or a
///   throw records nothing. Its result is trimmed as Dart's `String.trim`.
///   Query strings, headers, request bodies, and error text are never read.
///
/// Events arrive on the monitor's own serial `queue`. Nothing here throws
/// or traps into the app, and requests and responses are unchanged.
public final class TugboatAlamofireMonitor: EventMonitor, @unchecked Sendable {
  public let queue = DispatchQueue(label: "com.gettugboat.sdk.alamofire-monitor")

  /// One `Request`'s call. Kept until the request is released, so a
  /// retry after it finished is not a second call.
  private struct Entry {
    weak var request: Request?
    let call: TugboatNetworkCall?
    var finished = false
  }

  private let routeResolver: TugboatRouteResolver
  /// Only touched on `queue`.
  private var entries: [ObjectIdentifier: Entry] = [:]

  /// `routeResolver` maps a request to a bounded route path, such as
  /// `/orders/{id}` or `/orders/123`: never a URL, query, or fragment.
  public init(routeResolver: @escaping TugboatRouteResolver) {
    self.routeResolver = routeResolver
  }

  public func request(_ request: Request, didCreateURLRequest urlRequest: URLRequest) {
    let key = ObjectIdentifier(request)
    if let entry = entries[key], entry.request === request {
      return
    }
    pruneReleasedRequests()
    guard TugboatAdapters.isAcceptingEvidence else {
      entries[key] = Entry(request: request, call: nil)
      return
    }
    let route = TugboatAdapters.route(for: urlRequest, routeResolver)
    let call = route.map { TugboatAdapters.beginNetworkCall(method: urlRequest.httpMethod ?? "GET", route: $0) }
    entries[key] = Entry(request: request, call: call)
  }

  public func requestDidFinish(_ request: Request) {
    let key = ObjectIdentifier(request)
    guard var entry = entries[key], entry.request === request, !entry.finished else { return }
    entry.finished = true
    entries[key] = entry
    guard let call = entry.call else { return }
    let attemptCount = request.retryCount + 1
    if isCancelled(request) {
      call.fail(.cancelled, attemptCount: attemptCount)
    } else if let response = request.response {
      let status = response.statusCode
      call.complete(
        statusCode: status, attemptCount: attemptCount,
        errorResponseBody: status >= 400 ? errorBody(of: request, response: response) : nil)
    } else {
      call.fail(.networkError, attemptCount: attemptCount)
    }
  }

  private func isCancelled(_ request: Request) -> Bool {
    if request.isCancelled {
      return true
    }
    guard let error = request.error else { return false }
    if error.isExplicitlyCancelledError {
      return true
    }
    return (error.underlyingError as? URLError)?.code == .cancelled
  }

  private func errorBody(of request: Request, response: HTTPURLResponse) -> Any? {
    guard let data = (request as? DataRequest)?.data else { return nil }
    let contentType = response.allHeaderFields.first { (name, _) in
      (name as? String)?.caseInsensitiveCompare("Content-Type") == .orderedSame
    }?.value as? String
    return TugboatAdapters.errorResponseBody(bytes: data, contentType: contentType)
  }

  /// Drops entries whose request was released, once there are enough to
  /// matter.
  private func pruneReleasedRequests() {
    guard entries.count >= 64 else { return }
    entries = entries.filter { $0.value.request != nil }
  }
}
