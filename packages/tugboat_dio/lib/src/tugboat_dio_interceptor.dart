import 'package:dio/dio.dart';
import 'package:tugboat/tugboat.dart';

/// Host-supplied mapper from a Dio request to a safe route template.
///
/// Must return a bounded template such as `/blend/:blendId`, never a raw path
/// containing entity IDs. Return `null` or empty to drop the observation.
typedef TugboatDioRouteResolver = String? Function(RequestOptions request);

/// Records one logical Dio request as Tugboat `network_call` evidence.
///
/// Install **after** auth/retry interceptors. Dio runs error interceptors in
/// FIFO order, so retry handlers must run first and recover before this adapter
/// finishes the token. Prefer [install], which appends and rejects duplicate
/// installation on the same [Dio] instance.
///
/// Never inspects request/response bodies, headers, cookies, query parameters,
/// or raw error text.
class TugboatDioInterceptor extends Interceptor {
  TugboatDioInterceptor({required this.routeResolver});

  static const _extraCallKey = 'tugboat.network_call';

  final TugboatDioRouteResolver routeResolver;

  /// Installs a single interceptor at the end of [dio]'s chain.
  ///
  /// Returns `false` when a [TugboatDioInterceptor] is already present.
  static bool install(
    Dio dio, {
    required TugboatDioRouteResolver routeResolver,
  }) {
    if (dio.interceptors.any((i) => i is TugboatDioInterceptor)) {
      return false;
    }
    dio.interceptors.add(TugboatDioInterceptor(routeResolver: routeResolver));
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
      call?.complete(
        statusCode: response.statusCode,
        attemptCount: _attemptCount(options),
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
            statusCode: statusCode,
            attemptCount: attempts,
          );
        } else if (err.response != null) {
          // Logical HTTP response was available; retain status without error
          // text.
          call.complete(statusCode: statusCode, attemptCount: attempts);
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

  void _ensureToken(RequestOptions options) {
    if (!TugboatReplay.isAcceptingEvidence) return;

    final existing = options.extra[_extraCallKey];
    if (existing is _TugboatDioCallState) {
      existing.attemptCount += 1;
      return;
    }
    if (options.extra.containsKey(_extraCallKey)) {
      // A host owns this key. Fail open without invoking its resolver or
      // changing metadata that does not belong to this interceptor.
      return;
    }

    final controller = TugboatReplay.controller;
    final session = controller?.session;
    if (controller == null || session == null) return;

    String? route;
    try {
      route = routeResolver(options);
    } catch (_) {
      route = null;
    }
    if (!TugboatReplay.isAcceptingEvidence ||
        !identical(TugboatReplay.controller, controller) ||
        !identical(controller.session, session)) {
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
