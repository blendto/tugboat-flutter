import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat_dio/tugboat_dio.dart';

const _testConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
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

  testWidgets('200 response emits one network_call', (tester) async {
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

  testWidgets('resolver can preserve a dynamic route path', (tester) async {
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

  testWidgets('bad response retains status and bounded response body', (
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

  testWidgets('transport error emits network_error', (tester) async {
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

  testWidgets('cancellation emits cancelled', (tester) async {
    await _pumpCapture(tester);
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
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
  });

  testWidgets('auth retry emits one final logical event', (tester) async {
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

  testWidgets('accepted HTTP error still retains its response body', (
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

  testWidgets('unmatched route drops without event', (tester) async {
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

  testWidgets('unsafe resolver output drops without retaining URL data', (
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

  testWidgets('duplicate install is rejected', (tester) async {
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

  testWidgets('dormant tugboat leaves networking unchanged', (tester) async {
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

  testWidgets('disabled tugboat leaves request extras untouched', (
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

  testWidgets('ended session leaves request extras untouched', (tester) async {
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

  testWidgets('lifecycle change inside resolver does not attach metadata', (
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

  testWidgets('session replacement inside resolver does not cross sessions', (
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

  testWidgets('deactivate synchronously fences event and network evidence', (
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

  testWidgets('reserved extras survive a successful request', (tester) async {
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

  testWidgets('reserved extras survive a failed request', (tester) async {
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

  testWidgets('cached interceptor resolve emits one logical response', (
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
}
