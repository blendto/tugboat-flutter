import 'package:dio/dio.dart';
import 'package:tugboat/tugboat.dart';

/// Host-supplied mapper from a Dio request to a safe route template.
///
/// Must return a bounded template such as `/blend/:blendId`, never a raw path
/// containing entity IDs. Return `null` or empty to drop the observation.
typedef TugboatDioRouteResolver = String? Function(RequestOptions request);

/// Records one logical Dio request as Tugboat `network_call` evidence.
///
/// Install **before** auth/retry interceptors so interceptor-level retries
/// resolve before this adapter emits. Prefer [install], which inserts at index
/// `0` and rejects duplicate installation on the same [Dio] instance.
///
/// Never inspects request/response bodies, headers, cookies, query parameters,
/// or raw error text.
class TugboatDioInterceptor extends Interceptor {
  TugboatDioInterceptor({required this.routeResolver});

  static const extraCallKey = 'tugboat.network_call';
  static const extraAttemptCountKey = 'tugboat.network_attempt_count';

  final TugboatDioRouteResolver routeResolver;

  /// Installs a single interceptor at the start of [dio]'s chain.
  ///
  /// Returns `false` when a [TugboatDioInterceptor] is already present.
  static bool install(
    Dio dio, {
    required TugboatDioRouteResolver routeResolver,
  }) {
    if (dio.interceptors.any((i) => i is TugboatDioInterceptor)) {
      return false;
    }
    dio.interceptors.insert(
      0,
      TugboatDioInterceptor(routeResolver: routeResolver),
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
    try {
      final call = _tokenOf(response.requestOptions);
      call?.complete(
        statusCode: response.statusCode,
        attemptCount: _attemptCount(response.requestOptions),
      );
    } catch (_) {}
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    try {
      final call = _tokenOf(err.requestOptions);
      if (call != null) {
        final statusCode = err.response?.statusCode;
        final attempts = _attemptCount(err.requestOptions);
        if (err.type == DioExceptionType.cancel) {
          call.fail(
            outcome: TugboatNetworkOutcome.cancelled,
            statusCode: statusCode,
            attemptCount: attempts,
          );
        } else if (err.response != null) {
          // Logical HTTP response was available; retain status without error
          // text.
          call.complete(statusCode: statusCode, attemptCount: attempts);
        } else {
          call.fail(
            outcome: TugboatNetworkOutcome.networkError,
            statusCode: statusCode,
            attemptCount: attempts,
          );
        }
      }
    } catch (_) {}
    handler.next(err);
  }

  void _ensureToken(RequestOptions options) {
    final existing = options.extra[extraCallKey];
    if (existing is TugboatNetworkCall) {
      final attempts = options.extra[extraAttemptCountKey];
      final current = attempts is int ? attempts : 1;
      options.extra[extraAttemptCountKey] = current + 1;
      return;
    }

    String? route;
    try {
      route = routeResolver(options);
    } catch (_) {
      route = null;
    }
    final normalized = _normalizeRoute(route);
    final call = TugboatReplay.beginNetworkCall(
      method: options.method,
      // Empty route forces a bounded drop when the resolver rejected the call.
      route: normalized ?? '',
    );
    options.extra[extraCallKey] = call;
    options.extra[extraAttemptCountKey] = 1;
  }

  TugboatNetworkCall? _tokenOf(RequestOptions options) {
    final value = options.extra[extraCallKey];
    return value is TugboatNetworkCall ? value : null;
  }

  int? _attemptCount(RequestOptions options) {
    final value = options.extra[extraAttemptCountKey];
    return value is int ? value : null;
  }

  static String? _normalizeRoute(String? route) {
    if (route == null) return null;
    final trimmed = route.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.length > TugboatNetworkLimits.maxRouteLength) return null;
    return trimmed;
  }
}
