import 'package:dio/dio.dart';
import 'package:tugboat/tugboat.dart';

import 'error_body_url_policy.dart';

/// Host-supplied mapper from a Dio request to a bounded route path.
///
/// May retain dynamic identifier segments. Return `null` or empty to drop the
/// observation.
typedef TugboatDioRouteResolver = String? Function(RequestOptions request);

/// Records one logical Dio request as Tugboat `network_call` evidence.
///
/// Install **after** auth/retry interceptors. Dio runs error interceptors in
/// FIFO order, so retry handlers must run first and recover before this adapter
/// finishes the token. Prefer [install], which appends and rejects duplicate
/// installation on the same [Dio] instance.
///
/// Never inspects request bodies, successful response bodies, headers, cookies,
/// query parameters, or raw transport error text. Bounded JSON/text response
/// bodies are retained only for HTTP error statuses.
///
/// By default every HTTP error body is retained. [errorBodyDenyUrls] and
/// [errorBodyUrls] are opt-in controls over which request URLs may keep one.
/// Each entry is a case-insensitive `host[/path]` glob, for example
/// `api.example.com/v1/accounts/*`. `*` is the only wildcard: in the host part
/// it never spans into the path, in the path part it matches any run of
/// characters. A pattern with no `/` matches that whole host with any path. An
/// empty URL path counts as `/`. Only the host and path of `baseUrl` + `path`
/// are compared: the scheme, port, user-info, query, query parameters and
/// fragment are never inspected, and ports are not matched. A URL matching
/// [errorBodyDenyUrls] never keeps a body; when [errorBodyUrls] is non-null
/// only matching URLs may keep one (an empty list keeps none). Deny wins over
/// allow. A redirected response is checked at its request URL and at every
/// redirect hop (host and path only; hops are resolved one after another, so
/// a relative `Location` is read against the hop before it): any URL matching
/// a deny pattern drops the body, and an allow list must allow every URL. This
/// relies on the HTTP adapter reporting `Response.redirects`; the default IO
/// adapter does, and an adapter that does not only gets the request-URL check.
/// Paths are compared with dot segments resolved and runs of `/` collapsed. An
/// excluded URL still records its method, route, status, outcome and duration,
/// just without the body.
///
/// A pattern is not accepted (an `assert` fails in debug builds, and it never
/// throws while requests run) if it is blank or starts with `/`; contains
/// whitespace, a control or non-ASCII character, `?` or `#`; has `:`, `@`,
/// `[` or `]` in the host (no scheme, port, user-info or IPv6 literal); has one
/// of `[ ] { } | ^ " < >`, a backtick or a backslash in the path (use `%5B`
/// style escapes); has `//` or a `.` or `..` segment in the path; has a `%`
/// not followed by two literal hex digits; or escapes an unreserved character
/// such as `%7E` or `%41` (write it plainly). In release builds an unusable
/// [errorBodyDenyUrls] entry makes the interceptor drop every error body, and
/// an [errorBodyUrls] list with no usable pattern keeps none. An unparseable
/// URL also loses its body while either list is set.
class TugboatDioInterceptor extends Interceptor {
  TugboatDioInterceptor({
    required this.routeResolver,
    List<String> errorBodyDenyUrls = const [],
    List<String>? errorBodyUrls,
  }) : _errorBodyPolicy = ErrorBodyUrlPolicy(
         deny: errorBodyDenyUrls,
         allow: errorBodyUrls,
       );

  static const _extraCallKey = 'tugboat.network_call';

  final TugboatDioRouteResolver routeResolver;
  final ErrorBodyUrlPolicy _errorBodyPolicy;

  /// Installs a single interceptor at the end of [dio]'s chain.
  ///
  /// Returns `false` when a [TugboatDioInterceptor] is already present.
  /// [errorBodyDenyUrls] and [errorBodyUrls] are described on the class.
  static bool install(
    Dio dio, {
    required TugboatDioRouteResolver routeResolver,
    List<String> errorBodyDenyUrls = const [],
    List<String>? errorBodyUrls,
  }) {
    if (dio.interceptors.any((i) => i is TugboatDioInterceptor)) {
      return false;
    }
    dio.interceptors.add(
      TugboatDioInterceptor(
        routeResolver: routeResolver,
        errorBodyDenyUrls: errorBodyDenyUrls,
        errorBodyUrls: errorBodyUrls,
      ),
    );
    return true;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      _ensureToken(options);
    } catch (_) {
      // Observation failures must never affect host networking.
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final options = response.requestOptions;
    TugboatNetworkCall? call;
    try {
      call = _tokenOf(options);
      final statusCode = response.statusCode;
      call?.complete(
        statusCode: statusCode,
        attemptCount: _attemptCount(options),
        errorResponseBody: _isHttpError(statusCode)
            ? _retainedErrorBody(options, response.data, response)
            : null,
      );
    } catch (_) {
    } finally {
      if (call != null) _clearToken(options);
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    TugboatNetworkCall? call;
    try {
      call = _tokenOf(options);
      if (call != null) {
        final statusCode = err.response?.statusCode;
        final attempts = _attemptCount(options);
        if (err.type == DioExceptionType.cancel) {
          call.fail(
            failure: TugboatNetworkFailure.cancelled,
            attemptCount: attempts,
          );
        } else if (err.response != null) {
          // Logical HTTP response was available; retain status without error
          // text, but include its bounded HTTP error response body.
          call.complete(
            statusCode: statusCode,
            attemptCount: attempts,
            errorResponseBody: _retainedErrorBody(
              options,
              err.response?.data,
              err.response,
            ),
          );
        } else {
          call.fail(
            failure: TugboatNetworkFailure.networkError,
            statusCode: statusCode,
            attemptCount: attempts,
          );
        }
      }
    } catch (_) {
    } finally {
      if (call != null) _clearToken(options);
    }
    handler.next(err);
  }

  bool _isHttpError(int? statusCode) => statusCode != null && statusCode >= 400;

  /// [data] when the request URL, and every redirect hop after it, may keep an
  /// error body, otherwise `null`. Fails closed if a restricted policy
  /// cannot read a URL.
  Object? _retainedErrorBody(
    RequestOptions options,
    Object? data,
    Response<dynamic>? response,
  ) {
    if (_errorBodyPolicy.isUnrestricted) return data;
    try {
      final permitted = _errorBodyPolicy.permits(
        options.baseUrl,
        options.path,
        redirects: _redirectLocations(response),
      );
      return permitted ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// The `location` of every redirect the response went through, in order, or
  /// empty without redirects (or when the adapter does not report them). Each
  /// one can be relative to the previous hop, so the policy resolves the whole
  /// chain. Reading the records directly avoids `Response.realUri`, whose
  /// fallback to `RequestOptions.uri` would serialise query parameters.
  List<Uri> _redirectLocations(Response<dynamic>? response) {
    final redirects = response?.redirects;
    if (redirects == null) return const [];
    return [for (final redirect in redirects) redirect.location];
  }

  void _ensureToken(RequestOptions options) {
    if (!TugboatReplay.isAcceptingEvidence) return;
    final existing = _existingCallState(options);
    if (existing != null) {
      existing.attemptCount += 1;
      return;
    }
    if (!_mayStartCall(options)) {
      // A host owns this key. Fail open without invoking its resolver or
      // changing metadata that does not belong to this interceptor.
      return;
    }
    final controller = TugboatReplay.controller;
    final session = controller?.session;
    if (controller == null || session == null) return;
    final route = _resolveRoute(options);
    if (!_isCurrentCallOwner(controller, session)) {
      return;
    }

    final trimmed = route?.trim();
    options.extra[_extraCallKey] = _TugboatDioCallState(
      TugboatReplay.beginNetworkCall(
        method: options.method,
        route: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      ),
    );
  }

  _TugboatDioCallState? _existingCallState(RequestOptions options) {
    final existing = options.extra[_extraCallKey];
    return existing is _TugboatDioCallState ? existing : null;
  }

  bool _mayStartCall(RequestOptions options) =>
      TugboatReplay.isAcceptingEvidence &&
      !options.extra.containsKey(_extraCallKey);

  String? _resolveRoute(RequestOptions options) {
    try {
      return routeResolver(options);
    } catch (_) {
      return null;
    }
  }

  bool _isCurrentCallOwner(Object controller, Object session) =>
      TugboatReplay.isAcceptingEvidence &&
      identical(TugboatReplay.controller, controller) &&
      identical((controller as dynamic).session, session);

  TugboatNetworkCall? _tokenOf(RequestOptions options) {
    final value = options.extra[_extraCallKey];
    return value is _TugboatDioCallState ? value.call : null;
  }

  int? _attemptCount(RequestOptions options) {
    final value = options.extra[_extraCallKey];
    return value is _TugboatDioCallState ? value.attemptCount : null;
  }

  void _clearToken(RequestOptions options) {
    try {
      if (options.extra[_extraCallKey] is _TugboatDioCallState) {
        options.extra.remove(_extraCallKey);
      }
    } catch (_) {
      // Cleanup must never affect host networking.
    }
  }
}

class _TugboatDioCallState {
  _TugboatDioCallState(this.call);

  final TugboatNetworkCall call;
  int attemptCount = 1;
}
