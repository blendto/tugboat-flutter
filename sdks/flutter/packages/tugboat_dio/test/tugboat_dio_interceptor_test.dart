import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat_dio/tugboat_dio.dart';

const _testConfig = TugboatReplayConfig(
  enabled: true,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

Future<void> _pumpCapture(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _testConfig, child: child!),
      home: const SizedBox.expand(),
    ),
  );
  await tester.pump();
}

Future<T> _runAsync<T>(WidgetTester tester, Future<T> Function() body) {
  return tester.runAsync(body).then((value) {
    if (value is! T) {
      throw StateError('runAsync returned null');
    }
    return value;
  });
}

/// Lets in-flight capture work finish in real time, unmounts the app, disposes
/// the replay controller and advances fake time past every timer the SDK may
/// have scheduled (settle windows, delays, flush timers), so no timer is left
/// pending when the test body ends.
///
/// Capture work started by `_pumpCapture` resumes on real time (inside
/// `runAsync`), and the continuations then schedule fake-async timers at times
/// the test cannot predict. Without this, the framework's end-of-test check
/// "A Timer is still pending even after the widget tree was disposed" fails
/// intermittently.
Future<void> _settleCapture(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpWidget(const SizedBox.shrink());
  TugboatReplay.resetForTest();
  await tester.pump(const Duration(seconds: 10));
}

/// `testWidgets` that always settles capture timers before the test ends.
void _testCapture(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    Object? bodyError;
    StackTrace? bodyStack;
    try {
      await body(tester);
    } catch (error, stack) {
      bodyError = error;
      bodyStack = stack;
    }
    try {
      await _settleCapture(tester);
    } catch (error) {
      // A cleanup failure must never hide the test's own failure.
      if (bodyError == null) rethrow;
      debugPrint('settle failed after the test already failed: $error');
    }
    if (bodyError != null) Error.throwWithStackTrace(bodyError, bodyStack!);
  });
}

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => _handler(options);
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  _testCapture('200 response emits one network_call', (tester) async {
    await _pumpCapture(tester);
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString(
        '{"ok":true}',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    TugboatDioInterceptor.install(dio, routeResolver: (_) => '/blend/:blendId');

    final response = await _runAsync(
      tester,
      () => dio.get<dynamic>(
        '/blend/raw-id-should-not-appear?x=1',
        options: Options(extra: {'host.keep': 'value'}),
      ),
    );
    expect(response.requestOptions.extra, {'host.keep': 'value'});

    final events = TugboatReplay.controller!.session!.events
        .where((e) => e.type == 'network_call')
        .toList();
    expect(events, hasLength(1));
    final data = events.single.data;
    expect(data['method'], 'GET');
    expect(data['route'], '/blend/:blendId');
    expect(data['statusCode'], 200);
    expect(data['outcome'], 'response');
    expect(data['durationMs'], isA<int>());
    expect(data.toString().contains('raw-id'), isFalse);
    expect(data.toString().contains('example.test'), isFalse);
    expect(data.containsKey('headers'), isFalse);
    expect(data.containsKey('errorResponseBody'), isFalse);
  });

  _testCapture('resolver can preserve a dynamic route path', (tester) async {
    await _pumpCapture(tester);
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString('ok', 200),
    );
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/api/stores/4004584/websites',
    );

    await _runAsync(tester, () => dio.get<dynamic>('/ignored-by-resolver'));

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (event) => event.type == 'network_call',
    );
    expect(event.data['route'], '/api/stores/4004584/websites');
  });

  _testCapture('bad response retains status and bounded response body', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString('secret-body', 503),
    );
    dio.options.validateStatus = (status) => false;
    TugboatDioInterceptor.install(dio, routeResolver: (_) => '/health');

    await _runAsync(
      tester,
      () => expectLater(
        dio.get<dynamic>('/health'),
        throwsA(isA<DioException>()),
      ),
    );

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (e) => e.type == 'network_call',
    );
    expect(event.data['statusCode'], 503);
    expect(event.data['outcome'], 'response');
    expect(event.data['errorResponseBody'], 'secret-body');
    expect(event.data['errorResponseBodyCapture'], {
      'format': 'text',
      'representation': 'native',
      'truncated': false,
    });
  });

  _testCapture('transport error emits network_error', (tester) async {
    await _pumpCapture(tester);
    RequestOptions? observedRequest;
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      observedRequest = options;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'socket failed with user token abc',
      );
    });
    TugboatDioInterceptor.install(dio, routeResolver: (_) => '/sync');

    await _runAsync(
      tester,
      () => expectLater(
        dio.get<dynamic>(
          '/sync',
          options: Options(extra: {'host.keep': 'value'}),
        ),
        throwsA(isA<DioException>()),
      ),
    );
    expect(observedRequest!.extra, {'host.keep': 'value'});

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (e) => e.type == 'network_call',
    );
    expect(event.data['outcome'], 'network_error');
    expect(event.data.containsKey('statusCode'), isFalse);
    expect(event.data.toString().contains('token'), isFalse);
    expect(event.data.toString().contains('socket'), isFalse);
  });

  _testCapture('cancellation emits cancelled', (tester) async {
    await _pumpCapture(tester);
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
        response: Response<dynamic>(requestOptions: options, statusCode: 499),
      );
    });
    TugboatDioInterceptor.install(dio, routeResolver: (_) => '/long');

    await _runAsync(
      tester,
      () =>
          expectLater(dio.get<dynamic>('/long'), throwsA(isA<DioException>())),
    );

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (e) => e.type == 'network_call',
    );
    expect(event.data['outcome'], 'cancelled');
    expect(event.data.containsKey('statusCode'), isFalse);
  });

  _testCapture('auth retry emits one final logical event', (tester) async {
    await _pumpCapture(tester);
    final dio = Dio();
    var attempts = 0;
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      attempts += 1;
      if (attempts == 1) {
        return ResponseBody.fromString('unauthorized', 401);
      }
      return ResponseBody.fromString('ok', 200);
    });

    // Auth/retry first; Tugboat last so Dio's FIFO error handlers let auth
    // recover before observation finishes.
    dio.interceptors.add(
      QueuedInterceptorsWrapper(
        onError: (err, handler) async {
          if (err.response?.statusCode == 401) {
            final response = await dio.fetch<dynamic>(err.requestOptions);
            handler.resolve(response);
            return;
          }
          handler.next(err);
        },
      ),
    );
    TugboatDioInterceptor.install(dio, routeResolver: (_) => '/secure');

    final response = await _runAsync(tester, () => dio.get<dynamic>('/secure'));
    expect(response.statusCode, 200);
    expect(attempts, 2);

    final events = TugboatReplay.controller!.session!.events
        .where((e) => e.type == 'network_call')
        .toList();
    expect(events, hasLength(1));
    expect(events.single.data['statusCode'], 200);
    expect(events.single.data['outcome'], 'response');
    expect(events.single.data['attemptCount'], 2);
    expect(events.single.data.containsKey('errorResponseBody'), isFalse);
  });

  _testCapture('retry outside evidence admission keeps its attempt count', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final dio = Dio();
    var attempts = 0;
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      attempts += 1;
      if (attempts == 1) {
        return ResponseBody.fromString('unauthorized', 401);
      }
      TugboatReplay.lifecycle.setDisabled(false);
      return ResponseBody.fromString('ok', 200);
    });
    dio.interceptors.add(
      QueuedInterceptorsWrapper(
        onError: (err, handler) async {
          if (err.response?.statusCode == 401) {
            TugboatReplay.lifecycle.setDisabled(true);
            final response = await dio.fetch<dynamic>(err.requestOptions);
            handler.resolve(response);
            return;
          }
          handler.next(err);
        },
      ),
    );
    TugboatDioInterceptor.install(dio, routeResolver: (_) => '/secure');

    final response = await _runAsync(tester, () => dio.get<dynamic>('/secure'));
    expect(response.statusCode, 200);
    expect(attempts, 2);
    final events = TugboatReplay.controller!.session!.events
        .where((event) => event.type == 'network_call')
        .toList();
    expect(events, hasLength(1));
    expect(events.single.data['attemptCount'], 1);
  });

  _testCapture('accepted HTTP error still retains its response body', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final dio = Dio(
      BaseOptions(validateStatus: (status) => status != null && status < 600),
    );
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString(
        '{"code":"overloaded"}',
        503,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    TugboatDioInterceptor.install(dio, routeResolver: (_) => '/health');

    final response = await _runAsync(tester, () => dio.get<dynamic>('/health'));
    expect(response.statusCode, 503);

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (event) => event.type == 'network_call',
    );
    expect(event.data['errorResponseBody'], {'code': 'overloaded'});
    expect(event.data['errorResponseBodyCapture'], {
      'format': 'json',
      'representation': 'native',
      'truncated': false,
    });
  });

  _testCapture('unmatched route drops without event', (tester) async {
    await _pumpCapture(tester);
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString('ok', 200),
    );
    TugboatDioInterceptor.install(dio, routeResolver: (_) => null);

    await _runAsync(tester, () => dio.get<dynamic>('/mystery/id-123'));
    expect(
      TugboatReplay.controller!.session!.events.where(
        (e) => e.type == 'network_call',
      ),
      isEmpty,
    );
    expect(TugboatReplay.health.evidence.networkDropped, greaterThan(0));
    expect(
      TugboatReplay.health.toJson().toString().contains('id-123'),
      isFalse,
    );
  });

  _testCapture('unsafe resolver output drops without retaining URL data', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString('ok', 200),
    );
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => 'https://example.test/users/42?token=secret',
    );

    await _runAsync(tester, () => dio.get<dynamic>('/users/42?token=secret'));
    expect(
      TugboatReplay.controller!.session!.events.where(
        (e) => e.type == 'network_call',
      ),
      isEmpty,
    );
    expect(TugboatReplay.health.evidence.networkDropped, greaterThan(0));
    expect(TugboatReplay.health.toJson().toString().contains('secret'), false);
  });

  _testCapture('duplicate install is rejected', (tester) async {
    final dio = Dio();
    final first = TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/a',
    );
    final second = TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/b',
    );
    expect(first, isTrue);
    expect(second, isFalse);
    expect(dio.interceptors.whereType<TugboatDioInterceptor>(), hasLength(1));
  });

  _testCapture('dormant tugboat leaves networking unchanged', (tester) async {
    var resolverCalls = 0;
    RequestOptions? observedRequest;
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      observedRequest = options;
      return ResponseBody.fromString('ok', 200);
    });
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) {
        resolverCalls += 1;
        return '/x';
      },
    );

    final response = await _runAsync(
      tester,
      () => dio.get<dynamic>(
        '/x',
        options: Options(extra: {'host.keep': 'value'}),
      ),
    );
    expect(response.statusCode, 200);
    expect(TugboatReplay.controller, isNull);
    expect(resolverCalls, 0);
    expect(observedRequest!.extra, {'host.keep': 'value'});
  });

  _testCapture('disabled tugboat leaves request extras untouched', (
    tester,
  ) async {
    await _pumpCapture(tester);
    TugboatReplay.disabled = true;
    var resolverCalls = 0;
    RequestOptions? observedRequest;
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      observedRequest = options;
      return ResponseBody.fromString('ok', 200);
    });
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) {
        resolverCalls += 1;
        return '/x';
      },
    );

    final response = await _runAsync(
      tester,
      () => dio.get<dynamic>(
        '/x',
        options: Options(extra: {'host.keep': 'value'}),
      ),
    );

    expect(response.statusCode, 200);
    expect(resolverCalls, 0);
    expect(observedRequest!.extra, {'host.keep': 'value'});
  });

  _testCapture('ended session leaves request extras untouched', (tester) async {
    await _pumpCapture(tester);
    await TugboatReplay.controller!.endSession();
    var resolverCalls = 0;
    RequestOptions? observedRequest;
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      observedRequest = options;
      return ResponseBody.fromString('ok', 200);
    });
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) {
        resolverCalls += 1;
        return '/x';
      },
    );

    final response = await _runAsync(
      tester,
      () => dio.get<dynamic>(
        '/x',
        options: Options(extra: {'host.keep': 'value'}),
      ),
    );

    expect(response.statusCode, 200);
    expect(resolverCalls, 0);
    expect(observedRequest!.extra, {'host.keep': 'value'});
  });

  _testCapture('lifecycle change inside resolver does not attach metadata', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final controller = TugboatReplay.controller!;
    RequestOptions? observedRequest;
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      observedRequest = options;
      return ResponseBody.fromString('ok', 200);
    });
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) {
        unawaited(controller.endSession());
        return '/x';
      },
    );

    final response = await _runAsync(
      tester,
      () => dio.get<dynamic>(
        '/x',
        options: Options(extra: {'host.keep': 'value'}),
      ),
    );

    expect(response.statusCode, 200);
    expect(observedRequest!.extra, {'host.keep': 'value'});
    expect(
      controller.session!.events.where((e) => e.type == 'network_call'),
      isEmpty,
    );
  });

  _testCapture('session replacement inside resolver does not cross sessions', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final controller = TugboatReplay.controller!;
    final originalSession = controller.session!;
    RequestOptions? observedRequest;
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      observedRequest = options;
      return ResponseBody.fromString('ok', 200);
    });
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) {
        controller.clear();
        return '/x';
      },
    );

    final response = await _runAsync(
      tester,
      () => dio.get<dynamic>(
        '/x',
        options: Options(extra: {'host.keep': 'value'}),
      ),
    );

    final replacementSession = controller.session!;
    expect(response.statusCode, 200);
    expect(identical(replacementSession, originalSession), isFalse);
    expect(observedRequest!.extra, {'host.keep': 'value'});
    expect(
      originalSession.events.where((event) => event.type == 'network_call'),
      isEmpty,
    );
    expect(
      replacementSession.events.where((event) => event.type == 'network_call'),
      isEmpty,
    );
  });

  _testCapture('deactivate synchronously fences event and network evidence', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final controller = TugboatReplay.controller!;
    var resolverCalls = 0;
    RequestOptions? observedRequest;
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      observedRequest = options;
      return ResponseBody.fromString('ok', 200);
    });
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) {
        resolverCalls += 1;
        return '/after-deactivate';
      },
    );

    TugboatReplay.deactivate();
    TugboatReplay.eventHook().record('AFTER_DEACTIVATE');
    final response = await _runAsync(
      tester,
      () => dio.get<dynamic>(
        '/after-deactivate',
        options: Options(extra: {'host.keep': 'value'}),
      ),
    );

    expect(response.statusCode, 200);
    expect(TugboatReplay.isAcceptingEvidence, isFalse);
    expect(resolverCalls, 0);
    expect(observedRequest!.extra, {'host.keep': 'value'});
    expect(
      controller.session!.events.where(
        (event) =>
            event.type == 'external_event' || event.type == 'network_call',
      ),
      isEmpty,
    );
  });

  _testCapture('reserved extras survive a successful request', (tester) async {
    await _pumpCapture(tester);
    var resolverCalls = 0;
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString('ok', 200),
    );
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) {
        resolverCalls += 1;
        return '/collision';
      },
    );
    final hostExtras = <String, Object?>{
      'tugboat.network_call': 'host-call',
      'tugboat.network_attempt_count': 'host-attempts',
    };

    final response = await _runAsync(
      tester,
      () => dio.get<dynamic>('/collision', options: Options(extra: hostExtras)),
    );

    expect(response.statusCode, 200);
    expect(response.requestOptions.extra, hostExtras);
    expect(resolverCalls, 0);
    expect(
      TugboatReplay.controller!.session!.events.where(
        (event) => event.type == 'network_call',
      ),
      isEmpty,
    );
  });

  _testCapture('reserved extras survive a failed request', (tester) async {
    await _pumpCapture(tester);
    var resolverCalls = 0;
    RequestOptions? observedRequest;
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      observedRequest = options;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    });
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) {
        resolverCalls += 1;
        return '/collision';
      },
    );
    final hostExtras = <String, Object?>{
      'tugboat.network_call': 'host-call',
      'tugboat.network_attempt_count': 'host-attempts',
    };

    await _runAsync(
      tester,
      () => expectLater(
        dio.get<dynamic>('/collision', options: Options(extra: hostExtras)),
        throwsA(isA<DioException>()),
      ),
    );

    expect(observedRequest!.extra, hostExtras);
    expect(resolverCalls, 0);
    expect(
      TugboatReplay.controller!.session!.events.where(
        (event) => event.type == 'network_call',
      ),
      isEmpty,
    );
  });

  _testCapture('cached interceptor resolve emits one logical response', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final dio = Dio();
    // Short-circuit after Tugboat's onRequest, and call following response
    // interceptors so the observation can finish.
    TugboatDioInterceptor.install(dio, routeResolver: (_) => '/cached');
    // Move Tugboat before the cache short-circuit by rebuilding order:
    final tugboat = dio.interceptors.whereType<TugboatDioInterceptor>().single;
    dio.interceptors
      ..clear()
      ..add(tugboat)
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {'cached': true},
              ),
              true, // call following response interceptors
            );
          },
        ),
      );

    final response = await _runAsync(tester, () => dio.get<dynamic>('/cached'));
    expect(response.statusCode, 200);
    final events = TugboatReplay.controller!.session!.events
        .where((e) => e.type == 'network_call')
        .toList();
    expect(events, hasLength(1));
    expect(events.single.data['statusCode'], 200);
    expect(events.single.data['outcome'], 'response');
  });

  group('error body URL controls', () {
    // Sends GET [url] to a scripted 404 with an email in its body, through an
    // interceptor built from the given lists, and returns the network_call
    // data. [throwOnError] picks the DioException path over the response path.
    Future<Map<String, Object?>> send(
      WidgetTester tester,
      String url, {
      List<String> deny = const [],
      List<String>? allow,
      bool throwOnError = false,
      String baseUrl = '',
      Map<String, dynamic>? query,
      List<Uri>? redirects,
    }) async {
      await _pumpCapture(tester);
      final dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          validateStatus: (status) => !throwOnError,
        ),
      );
      const body = 'no account for someone@example.com';
      dio.httpClientAdapter = _ScriptedAdapter(
        (_) async => redirects == null
            ? ResponseBody.fromString(body, 404)
            : ResponseBody(
                Stream.value(Uint8List.fromList(body.codeUnits)),
                404,
                isRedirect: true,
                redirects: [
                  for (final to in redirects) RedirectRecord(302, 'GET', to),
                ],
              ),
      );
      TugboatDioInterceptor.install(
        dio,
        routeResolver: (_) => '/accounts/:id',
        errorBodyDenyUrls: deny,
        errorBodyUrls: allow,
      );
      await _runAsync(tester, () async {
        try {
          await dio.get<dynamic>(url, queryParameters: query);
        } on DioException {
          // Expected on the DioException path.
        }
      });
      return TugboatReplay.controller!.session!.events
          .singleWhere((e) => e.type == 'network_call')
          .data;
    }

    void expectBodyKept(Map<String, Object?> data) {
      expect(data['errorResponseBody'], 'no account for someone@example.com');
      expect(data['errorResponseBodyCapture'], isNotNull);
    }

    void expectBodyDropped(Map<String, Object?> data) {
      expect(data.containsKey('errorResponseBody'), isFalse);
      expect(data.containsKey('errorResponseBodyCapture'), isFalse);
      // The rest of the evidence is unchanged.
      expect(data['method'], 'GET');
      expect(data['route'], '/accounts/:id');
      expect(data['statusCode'], 404);
      expect(data['outcome'], 'response');
      expect(data['durationMs'], isA<int>());
    }

    const url = 'https://api.example.test/v1/accounts/42';

    for (final throwOnError in [false, true]) {
      final path = throwOnError ? 'DioException path' : 'response path';

      _testCapture('default keeps every body ($path)', (tester) async {
        expectBodyKept(await send(tester, url, throwOnError: throwOnError));
      });

      _testCapture('deny drops a matching body ($path)', (tester) async {
        final data = await send(
          tester,
          url,
          deny: ['api.example.test/v1/accounts/*'],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('deny leaves a non-matching URL alone ($path)', (
        tester,
      ) async {
        final data = await send(
          tester,
          url,
          deny: ['api.example.test/v1/billing/*'],
          throwOnError: throwOnError,
        );
        expectBodyKept(data);
      });

      _testCapture('allow keeps a matching body ($path)', (tester) async {
        final data = await send(
          tester,
          url,
          allow: ['api.example.test/v1/*'],
          throwOnError: throwOnError,
        );
        expectBodyKept(data);
      });

      _testCapture('allow list with no match drops the body ($path)', (
        tester,
      ) async {
        final data = await send(
          tester,
          url,
          allow: ['other.example.test/*'],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('deny beats allow ($path)', (tester) async {
        final data = await send(
          tester,
          url,
          deny: ['*/v1/accounts/*'],
          allow: ['api.example.test/*'],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('patterns ignore case ($path)', (tester) async {
        final data = await send(
          tester,
          'https://API.Example.test/V1/Accounts/42',
          deny: ['api.EXAMPLE.test/v1/ACCOUNTS/*'],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('query and fragment are never matched ($path)', (
        tester,
      ) async {
        const tricky =
            'https://api.example.test/v1/health'
            '?email=someone@example.com&next=/accounts#accounts';
        // A deny pattern that only the query/fragment could satisfy does not
        // drop the body.
        expectBodyKept(
          await send(
            tester,
            tricky,
            deny: ['*/*someone*', '*/*accounts*', '*someone*'],
            throwOnError: throwOnError,
          ),
        );
      });

      _testCapture('allow pattern cannot be satisfied by the query ($path)', (
        tester,
      ) async {
        const tricky = 'https://api.example.test/v1/health?x=/accounts/42';
        expectBodyDropped(
          await send(
            tester,
            tricky,
            allow: ['*/*accounts*'],
            throwOnError: throwOnError,
          ),
        );
      });

      _testCapture('undenied request redirected to a denied URL drops the body '
          '($path)', (tester) async {
        final data = await send(
          tester,
          url,
          deny: ['evil.test'],
          redirects: [Uri.parse('https://evil.test/landing?x=1')],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('redirect to an unlisted URL keeps the body ($path)', (
        tester,
      ) async {
        final data = await send(
          tester,
          url,
          deny: ['evil.test'],
          redirects: [Uri.parse('https://api.example.test/v1/next')],
          throwOnError: throwOnError,
        );
        expectBodyKept(data);
      });

      _testCapture('allowed request redirected outside the allow list drops '
          'the body ($path)', (tester) async {
        final data = await send(
          tester,
          url,
          allow: ['api.example.test/*'],
          redirects: [Uri.parse('https://other.test/x')],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('allowed request redirected within the allow list keeps '
          'the body ($path)', (tester) async {
        final data = await send(
          tester,
          url,
          allow: ['api.example.test/*'],
          redirects: [Uri.parse('https://api.example.test/v1/next')],
          throwOnError: throwOnError,
        );
        expectBodyKept(data);
      });

      _testCapture('two-hop chain with a relative last Location uses the hop '
          'host ($path)', (tester) async {
        final data = await send(
          tester,
          'https://api.example.test/start',
          deny: ['sso.example.test'],
          redirects: [
            Uri.parse('https://sso.example.test/login'),
            Uri.parse('/error'),
          ],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('relative first hop resolves against the request URL '
          '($path)', (tester) async {
        final data = await send(
          tester,
          'https://api.example.test/a/b',
          deny: ['api.example.test/a/sub/*'],
          redirects: [Uri.parse('sub/x'), Uri.parse('y')],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('denied intermediate hop drops the body ($path)', (
        tester,
      ) async {
        final data = await send(
          tester,
          url,
          deny: ['evil.test'],
          redirects: [
            Uri.parse('https://evil.test/hop'),
            Uri.parse('https://api.example.test/back'),
          ],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('allow list with a hop outside it drops the body ($path)', (
        tester,
      ) async {
        final data = await send(
          tester,
          url,
          allow: ['api.example.test/*'],
          redirects: [
            Uri.parse('https://other.test/hop'),
            Uri.parse('https://api.example.test/back'),
          ],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      // Each redirect test below resolves hops against the hop BEFORE it; it
      // would give the opposite answer if hops were resolved against the
      // request URL.
      _testCapture('deny on the second hop path resolved against hop one '
          '($path)', (tester) async {
        // Right: sso.example.test/error (denied); against the request URL it
        // would be api.example.test/error (not denied).
        final data = await send(
          tester,
          'https://api.example.test/start',
          deny: ['sso.example.test/error'],
          redirects: [
            Uri.parse('https://sso.example.test/login'),
            Uri.parse('/error'),
          ],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('allow list rejects a second hop resolved against hop one '
          '($path)', (tester) async {
        // Right: sso.example.test/error (not allowed); against the request URL
        // it would be api.example.test/error (allowed by the first pattern).
        final data = await send(
          tester,
          'https://api.example.test/start',
          allow: ['api.example.test/*', 'sso.example.test/login'],
          redirects: [
            Uri.parse('https://sso.example.test/login'),
            Uri.parse('/error'),
          ],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('relative first hop is allowed only via the request '
          'directory ($path)', (tester) async {
        // Right: /a/b/c + "d" = /a/b/d (allowed); against the host root it
        // would be /d (outside the allow list).
        final data = await send(
          tester,
          'https://api.example.test/a/b/c',
          allow: ['api.example.test/a/b/*'],
          redirects: [Uri.parse('d')],
          throwOnError: throwOnError,
        );
        expectBodyKept(data);
      });

      _testCapture('second relative hop is denied only via the previous hop '
          '($path)', (tester) async {
        // Right: /a/x/one then /a/x/two (denied); against the request URL the
        // second hop would be /a/two (not denied).
        final data = await send(
          tester,
          'https://api.example.test/a/b',
          deny: ['api.example.test/a/x/two'],
          redirects: [Uri.parse('x/one'), Uri.parse('two')],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });

      _testCapture('second relative hop is allowed only via the previous hop '
          '($path)', (tester) async {
        // Right: /a/x/two (allowed); against the request URL it would be
        // /a/two (outside the allow list).
        final data = await send(
          tester,
          'https://api.example.test/a/b',
          allow: ['api.example.test/a/b', 'api.example.test/a/x/*'],
          redirects: [Uri.parse('x/one'), Uri.parse('two')],
          throwOnError: throwOnError,
        );
        expectBodyKept(data);
      });

      _testCapture('port and user-info are not matched ($path)', (
        tester,
      ) async {
        final data = await send(
          tester,
          'https://user:secret@api.example.test:8443/v1/health',
          deny: ['*secret*', '*8443*'],
          throwOnError: throwOnError,
        );
        expectBodyKept(data);
      });

      _testCapture('port and user-info do not block a path match ($path)', (
        tester,
      ) async {
        final data = await send(
          tester,
          'https://user:secret@api.example.test:8443/v1/accounts/42',
          deny: ['api.example.test/v1/accounts/*'],
          throwOnError: throwOnError,
        );
        expectBodyDropped(data);
      });
    }

    _testCapture('queryParameters never influence the decision', (
      tester,
    ) async {
      final data = await send(
        tester,
        '/v1/health',
        baseUrl: 'https://api.example.test',
        deny: ['*/*accounts*', '*/*someone*'],
        query: {
          'next': '/v1/accounts/42',
          'email': 'someone@example.com',
          'ids': [1, 2, 3],
        },
      );
      expectBodyKept(data);
    });

    _testCapture('a path match still applies when queryParameters are set', (
      tester,
    ) async {
      final data = await send(
        tester,
        '/v1/accounts/42',
        baseUrl: 'https://api.example.test',
        deny: ['api.example.test/v1/accounts/*'],
        query: {'email': 'someone@example.com'},
      );
      expectBodyDropped(data);
    });

    _testCapture('the baseUrl path is part of the matched path', (
      tester,
    ) async {
      final data = await send(
        tester,
        '/v1/accounts/42',
        baseUrl: 'https://api.example.test/api/',
        deny: ['api.example.test/api/v1/accounts/*'],
      );
      expectBodyDropped(data);
    });

    _testCapture('a root URL matches host/*', (tester) async {
      final data = await send(
        tester,
        'https://api.example.test',
        deny: ['api.example.test/*'],
      );
      expectBodyDropped(data);
    });

    _testCapture('a bare host pattern covers every path on that host', (
      tester,
    ) async {
      final data = await send(
        tester,
        'https://api.example.test/v1/accounts/42',
        deny: ['api.example.test'],
      );
      expectBodyDropped(data);
    });

    _testCapture(
      'an unparseable URL under a restricted policy drops the body',
      (tester) async {
        final data = await send(
          tester,
          'http://[bad/x',
          deny: ['other.test/*'],
        );
        expectBodyDropped(data);
      },
    );

    _testCapture('does not affect a successful response', (tester) async {
      await _pumpCapture(tester);
      final dio = Dio();
      dio.httpClientAdapter = _ScriptedAdapter(
        (_) async => ResponseBody.fromString('ok', 200),
      );
      TugboatDioInterceptor.install(
        dio,
        routeResolver: (_) => '/health',
        errorBodyUrls: const [],
      );

      await _runAsync(tester, () => dio.get<dynamic>(url));

      final data = TugboatReplay.controller!.session!.events
          .singleWhere((e) => e.type == 'network_call')
          .data;
      expect(data['statusCode'], 200);
      expect(data.containsKey('errorResponseBody'), isFalse);
    });

    test('unusable patterns assert at construction, not at request time', () {
      expect(
        () => TugboatDioInterceptor(
          routeResolver: (_) => '/x',
          errorBodyDenyUrls: ['api.example.test/x?email=*'],
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
