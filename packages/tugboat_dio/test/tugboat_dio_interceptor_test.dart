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
      (_) async => ResponseBody.fromString('{"ok":true}', 200),
    );
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/blend/:blendId',
    );

    await dio.get<dynamic>('/blend/raw-id-should-not-appear?x=1');

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
  });

  testWidgets('bad response retains status without raw error', (tester) async {
    await _pumpCapture(tester);
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString('secret-body', 503),
    );
    dio.options.validateStatus = (status) => false;
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/health',
    );

    await expectLater(dio.get<dynamic>('/health'), throwsA(isA<DioException>()));

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (e) => e.type == 'network_call',
    );
    expect(event.data['statusCode'], 503);
    expect(event.data['outcome'], 'response');
    expect(event.data.toString().contains('secret-body'), isFalse);
  });

  testWidgets('transport error emits network_error', (tester) async {
    await _pumpCapture(tester);
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter((options) async {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'socket failed with user token abc',
      );
    });
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/sync',
    );

    await expectLater(dio.get<dynamic>('/sync'), throwsA(isA<DioException>()));

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
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/long',
    );

    await expectLater(dio.get<dynamic>('/long'), throwsA(isA<DioException>()));

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

    // Tugboat first (index 0), auth after — auth handles 401 before Tugboat
    // finishes on the error path.
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/secure',
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (err, handler) async {
          if (err.response?.statusCode == 401) {
            final opts = err.requestOptions;
            final response = await dio.fetch<dynamic>(opts);
            handler.resolve(response);
            return;
          }
          handler.next(err);
        },
      ),
    );

    final response = await dio.get<dynamic>('/secure');
    expect(response.statusCode, 200);
    expect(attempts, 2);

    final events = TugboatReplay.controller!.session!.events
        .where((e) => e.type == 'network_call')
        .toList();
    expect(events, hasLength(1));
    expect(events.single.data['statusCode'], 200);
    expect(events.single.data['outcome'], 'response');
    expect(events.single.data['attemptCount'], 2);
  });

  testWidgets('unmatched route drops without event', (tester) async {
    await _pumpCapture(tester);
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString('ok', 200),
    );
    TugboatDioInterceptor.install(dio, routeResolver: (_) => null);

    await dio.get<dynamic>('/mystery/id-123');
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
    final dio = Dio();
    dio.httpClientAdapter = _ScriptedAdapter(
      (_) async => ResponseBody.fromString('ok', 200),
    );
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/x',
    );

    final response = await dio.get<dynamic>('/x');
    expect(response.statusCode, 200);
    expect(TugboatReplay.controller, isNull);
  });

  testWidgets('cached interceptor resolve emits one logical response', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final dio = Dio();
    TugboatDioInterceptor.install(
      dio,
      routeResolver: (_) => '/cached',
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {'cached': true},
            ),
          );
        },
      ),
    );

    final response = await dio.get<dynamic>('/cached');
    expect(response.statusCode, 200);
    final events = TugboatReplay.controller!.session!.events
        .where((e) => e.type == 'network_call')
        .toList();
    expect(events, hasLength(1));
    expect(events.single.data['statusCode'], 200);
    expect(events.single.data['outcome'], 'response');
  });
}
