import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tugboat/src/capture_sink.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_http_sink.dart';
import 'package:tugboat/src/models.dart';
import 'package:tugboat/src/screenshot_capture_backend.dart';
import 'package:tugboat/src/sdk_version.dart';

/// A stopwatch the test advances by hand, standing in for the monotonic clock.
class _FakeStopwatch implements Stopwatch {
  Duration time = Duration.zero;
  bool _running = false;

  @override
  int get frequency => 1000000;

  @override
  Duration get elapsed => time;

  @override
  int get elapsedMicroseconds => time.inMicroseconds;

  @override
  int get elapsedMilliseconds => time.inMilliseconds;

  @override
  int get elapsedTicks => time.inMicroseconds;

  @override
  bool get isRunning => _running;

  @override
  void reset() => time = Duration.zero;

  @override
  void start() => _running = true;

  @override
  void stop() => _running = false;
}

void main() {
  late HttpServer server;
  late Uri baseUri;
  final sessionPosts = <Map<String, dynamic>>[];
  final batchPosts = <List<Map<String, dynamic>>>[];
  final framePosts = <Map<String, dynamic>>[];
  final requestOrder = <String>[];
  final headersByPath = <String, List<Map<String, String?>>>{};
  var eventStatus = 202;
  var frameStatus = 202;
  String? rejectedFrameNo;
  var sessionStatus = 202;
  var sessionFailuresRemaining = 0;
  var eventResponseDelay = Duration.zero;
  var frameResponseDelay = Duration.zero;
  String? sessionResponseTraitsId;

  /// When non-null, written verbatim as the `/v1/sessions` response body
  /// (including `''` for empty). When null, the default JSON acceptance map
  /// is used.
  String? sessionResponseBody;

  final collectorConfig = TugboatCollectorConfig(
    baseUrl: 'http://127.0.0.1:0',
    apiKey: 'pmk_test',
    eventBatchSize: 10,
    eventFlushInterval: const Duration(hours: 1),
    appInfo: const TugboatCollectorAppInfo(
      name: 'Example App',
      version: '1.0.0',
      buildNumber: '1',
      installationId: 'inst_1',
      appId: 'com.example.app',
    ),
    deviceInfo: const TugboatCollectorDeviceInfo(
      id: 'device_client',
      platform: 'ios',
      screenSize: TugboatCollectorScreenSize(width: 390, height: 844),
      screenDensity: 3,
      screenDpi: 460,
      screenPixelDensity: 3,
    ),
    ipInfo: const TugboatCollectorIpInfo(ip: '127.0.0.1'),
    locale: const TugboatCollectorLocaleInfo(language: 'en'),
  );

  setUp(() async {
    sessionPosts.clear();
    batchPosts.clear();
    framePosts.clear();
    requestOrder.clear();
    headersByPath.clear();
    eventStatus = 202;
    frameStatus = 202;
    rejectedFrameNo = null;
    sessionStatus = 202;
    sessionFailuresRemaining = 0;
    eventResponseDelay = Duration.zero;
    frameResponseDelay = Duration.zero;
    sessionResponseTraitsId = null;
    sessionResponseBody = null;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUri = Uri.parse('http://127.0.0.1:${server.port}');

    server.listen((request) async {
      final path = request.uri.path;
      (headersByPath[path] ??= []).add({
        'X-Platform': request.headers.value('X-Platform'),
        'X-App-Build': request.headers.value('X-App-Build'),
        'X-App-Version': request.headers.value('X-App-Version'),
        'X-App-Id': request.headers.value('X-App-Id'),
        'X-Sdk-Version': request.headers.value('X-Sdk-Version'),
      });
      if (path == '/v1/sessions') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        sessionPosts.add(Map<String, dynamic>.from(body));
        requestOrder.add('$path:${body['eventType']}');
        final status = sessionFailuresRemaining > 0
            ? (() {
                sessionFailuresRemaining -= 1;
                return 503;
              })()
            : sessionStatus;
        request.response.statusCode = status;
        final overrideBody = sessionResponseBody;
        if (overrideBody != null) {
          if (overrideBody.isNotEmpty) {
            request.response.write(overrideBody);
          }
        } else {
          request.response.write(
            jsonEncode({
              'accepted': true,
              'sessionId': 'sess_server',
              if (sessionResponseTraitsId != null)
                'traitsId': sessionResponseTraitsId,
            }),
          );
        }
      } else if (path == '/v1/events/batch') {
        requestOrder.add(path);
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final events = (body['events'] as List)
            .map((event) => Map<String, dynamic>.from(event as Map))
            .toList();
        batchPosts.add(events);
        if (eventResponseDelay > Duration.zero) {
          await Future<void>.delayed(eventResponseDelay);
        }
        request.response
          ..statusCode = eventStatus
          ..write(
            jsonEncode({
              'accepted': true,
              'ids': events.map((event) => event['id']).toList(),
            }),
          );
      } else if (path == '/v1/frames') {
        requestOrder.add(path);
        final contentType = request.headers.contentType;
        final boundary = contentType?.parameters['boundary'];
        expect(boundary, isNotNull);
        final bodyBytes = await request.fold<BytesBuilder>(
          BytesBuilder(),
          (builder, data) => builder..add(data),
        );
        final bytes = bodyBytes.takeBytes();
        final encodedBody = latin1.decode(bytes);
        final frameMetadataMatch = RegExp(
          r'name="frameMetadata"\r?\n\r?\n(\[[\s\S]*?\])\r?\n--',
        ).firstMatch(encodedBody);
        final frameNos = RegExp(
          r'filename="(\d+)\.jpg"',
        ).allMatches(encodedBody).map((match) => match.group(1)).toList();
        final responseStatus = frameNos.contains(rejectedFrameNo)
            ? 400
            : frameStatus;
        framePosts.add({
          'contentType': contentType?.mimeType,
          'bytes': bytes,
          'frameNos': frameNos,
          'status': responseStatus,
          if (frameMetadataMatch != null)
            'frameMetadata': jsonDecode(frameMetadataMatch.group(1)!),
        });
        if (frameResponseDelay > Duration.zero) {
          await Future<void>.delayed(frameResponseDelay);
        }
        request.response
          ..statusCode = responseStatus
          ..write(
            jsonEncode({
              'accepted': true,
              'keys': ['sess_server/0.png'],
            }),
          );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  TugboatCollectorConfig configForServer({
    int maxPendingBatches = 20,
    int maxPendingEvents = 200,
    int maxPendingFrames = 50,
    int maxPendingFrameBytes = 8 * 1024 * 1024,
  }) {
    return TugboatCollectorConfig(
      baseUrl: baseUri.toString(),
      apiKey: collectorConfig.apiKey,
      eventBatchSize: collectorConfig.eventBatchSize,
      eventFlushInterval: collectorConfig.eventFlushInterval,
      maxPendingBatches: maxPendingBatches,
      maxPendingEvents: maxPendingEvents,
      maxPendingFrames: maxPendingFrames,
      maxPendingFrameBytes: maxPendingFrameBytes,
      appInfo: collectorConfig.appInfo,
      deviceInfo: collectorConfig.deviceInfo,
      ipInfo: collectorConfig.ipInfo,
      locale: collectorConfig.locale,
    );
  }

  TugboatSession createSession({
    String id = 'session-local',
    TugboatLocaleInfo? locale,
  }) {
    return TugboatSession(
      id: id,
      startedAt: DateTime.utc(2026, 6, 19),
      platform: 'ios',
      viewport: const TugboatRect(0, 0, 390, 844),
      locale: locale,
    );
  }

  TugboatEvent createEvent(int index) {
    return TugboatEvent(
      id: 'event-$index',
      atMs: index,
      type: 'capture_diagnostic',
      data: {'index': index},
    );
  }

  void recordTestFrame(
    CollectorHttpSink sink,
    TugboatSession session,
    int frameNo, {
    int byteLength = 1,
  }) {
    sink.recordFrame(
      TugboatFrame(
        id: 'frame-$frameNo',
        atMs: frameNo,
        width: 1,
        height: 1,
        contentHash: 'hash-$frameNo',
      ),
      Uint8List(byteLength),
      sessionId: session.id,
    );
  }

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Diagnostic payloads for [component], once per event id (a retried
  /// batch is posted more than once).
  List<Map<String, dynamic>> diagnosticsFor(String component) {
    final seen = <Object?>{};
    return [
      for (final batch in batchPosts)
        for (final event in batch)
          if (event['payload'] is Map &&
              (event['payload'] as Map)['component'] == component &&
              seen.add(event['id']))
            Map<String, dynamic>.from(event['payload'] as Map),
    ];
  }

  test('HTTP proof lines redact secrets and unknown paths', () {
    expect(
      formatCollectorHttpProofLine(
        path: '/v1/sessions',
        localSessionId: 'session-local',
        returnedSessionId: 'sess_server',
        statusCode: 422,
        durationMs: 12,
      ),
      'TUGBOAT_HTTP method=POST path=/v1/sessions '
      'localSessionId=session-local returnedSessionId=sess_server '
      'status=422 durationMs=12',
    );
    expect(
      formatCollectorHttpProofLine(
        path: 'https://evil.example/secret?token=pmk_test',
        localSessionId: 'http://127.0.0.1/session',
        returnedSessionId: 'secret/response-body',
        durationMs: 4,
        error: StateError('secret-exception-url-token'),
      ),
      'TUGBOAT_HTTP method=POST path=redacted '
      'localSessionId=redacted returnedSessionId=redacted '
      'status=null durationMs=4 exception=StateError',
    );
  });

  test(
    'HTTP proof is opt-in and excludes rejection and exception secrets',
    () async {
      final messages = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) messages.add(message);
      };
      var fail = false;
      final sink = CollectorHttpSink(
        config: collectorConfig,
        client: MockClient((request) async {
          if (fail) throw StateError('secret-exception-url-token');
          return http.Response('secret-response-body', 422);
        }),
      );
      try {
        sink.startSession(createSession());
        await sink.flush();
        fail = true;
        await sink.flush();
        final output = messages.join('\n');
        expect(output, isEmpty);
        expect(output, isNot(contains('secret')));
        expect(output, isNot(contains('pmk_test')));
        expect(output, isNot(contains('127.0.0.1')));
      } finally {
        sink.dispose();
        debugPrint = original;
      }
    },
  );

  void expectCollectorHeaders(Map<String, String?> headers) {
    expect(headers['X-Platform'], collectorConfig.deviceInfo.platform);
    expect(headers['X-App-Build'], collectorConfig.appInfo.buildNumber);
    expect(headers['X-App-Version'], collectorConfig.appInfo.version);
    expect(headers['X-App-Id'], collectorConfig.appInfo.appId);
    expect(headers['X-Sdk-Version'], tugboatSdkVersion);
  }

  /// Short debounce so identity tests avoid ~3s wall-clock sleeps.
  const testIdentityDebounce = Duration(milliseconds: 40);

  CollectorHttpSink createIdentitySink({
    Map<String, dynamic>? initialTraits,
    String? initialTraitsId,
    String? initialUserId,
  }) {
    return CollectorHttpSink(
      config: configForServer(),
      initialTraits: initialTraits,
      initialTraitsId: initialTraitsId,
      initialUserId: initialUserId,
      identityDebounceDuration: testIdentityDebounce,
    );
  }

  Future<void> awaitIdentityDebounce() async {
    await Future<void>.delayed(
      testIdentityDebounce + const Duration(milliseconds: 40),
    );
  }

  test('collector defaults flush low-volume events every 3 seconds', () {
    expect(
      TugboatCollectorConfig(
        baseUrl: baseUri.toString(),
        apiKey: collectorConfig.apiKey,
        appInfo: collectorConfig.appInfo,
        deviceInfo: collectorConfig.deviceInfo,
        ipInfo: collectorConfig.ipInfo,
        locale: collectorConfig.locale,
      ).eventFlushInterval,
      const Duration(seconds: 3),
    );
  });

  test('posts mixed pan and zoom facts without renaming gestures', () async {
    final sink = CollectorHttpSink(config: configForServer());
    addTearDown(sink.dispose);
    sink.startSession(createSession());
    await sink.flush();

    const facts = [
      {
        'gesture': 'tap',
        'payload': {
          'position': {'xNorm': 0.5, 'yNorm': 0.5},
        },
      },
      {
        'gesture': 'swipe',
        'payload': {
          'pointerCount': 3,
          'delta': {'xNorm': 0.1, 'yNorm': 0.2},
        },
      },
      {
        'gesture': 'pan',
        'payload': {
          'pointerCount': 2,
          'delta': {'xNorm': 0.1, 'yNorm': 0.2},
        },
      },
      {
        'gesture': 'zoom_in',
        'payload': {'pointerCount': 2, 'scale': 1.4},
      },
      {
        'gesture': 'zoom_out',
        'payload': {'pointerCount': 2, 'scale': 0.7},
      },
    ];
    for (var i = 0; i < facts.length; i++) {
      sink.recordEvent(
        TugboatEvent(
          id: 'sdk-gesture-$i',
          atMs: i,
          type: 'interaction',
          stream: TugboatEventStream.semantic,
          data: {'interactionSchema': 2, 'route': '/canvas', ...facts[i]},
        ),
      );
    }
    await sink.flush();

    expect(batchPosts, hasLength(1));
    expect(batchPosts.single, hasLength(facts.length));
    for (var i = 0; i < facts.length; i++) {
      expect(
        batchPosts.single[i],
        containsPair('gesture', facts[i]['gesture']),
      );
      expect(batchPosts.single[i]['payload'], facts[i]['payload']);
      expect(batchPosts.single[i]['interactionSchema'], 2);
      expect(batchPosts.single[i]['route'], '/canvas');
      expect(batchPosts.single[i]['sessionId'], 'sess_server');
    }
  });

  test('posts session_start and batches events after 10 records', () async {
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession(
      locale: const TugboatLocaleInfo(
        language: 'es',
        country: 'ES',
        tag: 'es-ES',
      ),
    );
    sink.startSession(session);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sessionPosts, hasLength(1));
    expect(sessionPosts.first['eventType'], 'session_start');
    expect(sessionPosts.first['locale'], {
      'language': 'es',
      'country': 'ES',
      'tag': 'es-ES',
    });

    for (var i = 0; i < 9; i++) {
      sink.recordEvent(createEvent(i));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(batchPosts, isEmpty);

    sink.recordEvent(createEvent(9));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(batchPosts, hasLength(1));
    expect(batchPosts.first, hasLength(10));
    expect(batchPosts.first.first['sessionId'], 'sess_server');
    expect(batchPosts.first.first['eventType'], 'capture_diagnostic');
    expect(batchPosts.first.first['build'], isA<Map>());
    expect(
      (batchPosts.first.first['build'] as Map)['appId'],
      collectorConfig.appInfo.appId,
    );

    sink.dispose();
  });

  test('holds event flushes until session_start is accepted', () async {
    sessionStatus = 503;
    final sink = CollectorHttpSink(
      config: TugboatCollectorConfig(
        baseUrl: baseUri.toString(),
        apiKey: collectorConfig.apiKey,
        eventBatchSize: 2,
        eventFlushInterval: const Duration(hours: 1),
        appInfo: collectorConfig.appInfo,
        deviceInfo: collectorConfig.deviceInfo,
        ipInfo: collectorConfig.ipInfo,
        locale: collectorConfig.locale,
      ),
    );

    final session = createSession();
    sink.startSession(session);
    sink.recordEvent(createEvent(0));
    sink.recordEvent(createEvent(1));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(batchPosts, isEmpty);

    sessionStatus = 202;
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(batchPosts, isNotEmpty);
    expect(
      batchPosts
          .expand((batch) => batch)
          .every((event) => event['sessionId'] == 'sess_server'),
      isTrue,
    );
    sink.dispose();
  });

  test('stamps collector session id on events at send time', () async {
    sessionStatus = 503;
    final sink = CollectorHttpSink(
      config: TugboatCollectorConfig(
        baseUrl: baseUri.toString(),
        apiKey: collectorConfig.apiKey,
        eventBatchSize: 5,
        eventFlushInterval: const Duration(hours: 1),
        appInfo: collectorConfig.appInfo,
        deviceInfo: collectorConfig.deviceInfo,
        ipInfo: collectorConfig.ipInfo,
        locale: collectorConfig.locale,
      ),
    );

    final session = createSession();
    sink.startSession(session);
    sink.recordEvent(createEvent(0));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(batchPosts, isEmpty);

    sessionStatus = 202;
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(batchPosts, isNotEmpty);
    expect(
      batchPosts.first.where((event) => event['id'] == 'event-0').single,
      containsPair('sessionId', 'sess_server'),
    );
    sink.dispose();
  });

  test(
    'does not requeue stale event retries after a new session starts',
    () async {
      eventStatus = 503;
      eventResponseDelay = const Duration(milliseconds: 80);
      final sink = CollectorHttpSink(config: configForServer());
      sink.startSession(createSession());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      for (var i = 0; i < 10; i++) {
        sink.recordEvent(createEvent(i));
      }
      while (batchPosts.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      sink.startSession(createSession(id: 'session-new'));
      batchPosts.clear();
      eventStatus = 202;
      eventResponseDelay = Duration.zero;
      await Future<void>.delayed(const Duration(milliseconds: 140));

      for (var i = 100; i < 110; i++) {
        sink.recordEvent(createEvent(i));
      }
      await sink.flush();

      final deliveredIds = [
        for (final batch in batchPosts)
          for (final event in batch) event['id'] as String,
      ];
      expect(
        deliveredIds,
        containsAll([for (var i = 100; i < 110; i++) 'event-$i']),
      );
      expect(deliveredIds, isNot(contains('event-0')));
      sink.dispose();
    },
  );

  test('drops frames with malformed ids without throwing', () async {
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    sink.startSession(session);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    sink.recordFrame(
      const TugboatFrame(
        id: 'no-digits',
        atMs: 0,
        width: 1,
        height: 1,
        contentHash: 'hash',
      ),
      Uint8List.fromList([1]),
      sessionId: session.id,
    );
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(framePosts, isEmpty);
    sink.dispose();
  });

  test('uploads pending scroll and tap frames without superseding', () async {
    frameStatus = 503;
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    sink.startSession(session);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    sink.recordFrame(
      const TugboatFrame(
        id: 'frame-0',
        atMs: 0,
        width: 1,
        height: 1,
        contentHash: 'scroll-a',
        trigger: TugboatFrameTrigger.scroll,
      ),
      Uint8List.fromList([0]),
      sessionId: session.id,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    sink.recordFrame(
      const TugboatFrame(
        id: 'frame-1',
        atMs: 1,
        width: 1,
        height: 1,
        contentHash: 'scroll-b',
        trigger: TugboatFrameTrigger.scroll,
      ),
      Uint8List.fromList([1]),
      sessionId: session.id,
    );
    sink.recordFrame(
      const TugboatFrame(
        id: 'frame-2',
        atMs: 2,
        width: 1,
        height: 1,
        contentHash: 'tap-final',
        trigger: TugboatFrameTrigger.tap,
      ),
      Uint8List.fromList([2]),
      sessionId: session.id,
    );

    framePosts.clear();
    frameStatus = 202;
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(framePosts, isNotEmpty);
    final uploaded = framePosts.last['frameNos'] as List;
    expect(uploaded, ['0', '1', '2']);
    sink.dispose();
  });

  test(
    'isolates a rejected frame without discarding valid batch peers',
    () async {
      sessionStatus = 503;
      rejectedFrameNo = '2';
      final sink = CollectorHttpSink(config: configForServer());
      final session = createSession();
      sink.startSession(session);
      for (var i = 0; i < 5; i++) {
        sink.recordFrame(
          TugboatFrame(
            id: 'frame-$i',
            atMs: i,
            width: 1,
            height: 1,
            contentHash: 'hash-$i',
          ),
          Uint8List.fromList([i]),
          sessionId: session.id,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      sessionStatus = 202;
      await sink.flush();
      await sink.flush();

      final accepted = framePosts
          .where((post) => post['status'] == 202)
          .expand((post) => (post['frameNos'] as List).cast<String>())
          .toSet();
      expect(accepted, {'0', '1', '3', '4'});
      expect(framePosts.first['frameNos'], ['0', '1', '2', '3', '4']);
      final diagnostics = batchPosts.expand((batch) => batch).where((event) {
        final payload = event['payload'];
        return payload is Map &&
            payload['component'] == 'collector_frame_upload';
      }).toList();
      expect(diagnostics, hasLength(1));
      expect((diagnostics.single['payload'] as Map)['statusCode'], 400);
      sink.dispose();
    },
  );

  test(
    'uploads queued frames before publishing their referencing events',
    () async {
      sessionStatus = 503;
      final sink = CollectorHttpSink(config: configForServer());
      final session = createSession();
      sink.startSession(session);
      sink.recordEvent(
        const TugboatEvent(
          id: 'event-with-frame',
          atMs: 0,
          type: 'interaction',
          afterFrame: 'frame-0',
        ),
      );
      sink.recordFrame(
        const TugboatFrame(
          id: 'frame-0',
          atMs: 0,
          width: 1,
          height: 1,
          contentHash: 'frame-hash',
        ),
        Uint8List.fromList([0]),
        sessionId: session.id,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      requestOrder.clear();
      sessionStatus = 202;
      await sink.flush();
      await sink.flush();

      expect(
        requestOrder,
        containsAllInOrder(['/v1/frames', '/v1/events/batch']),
      );
      expect(framePosts, hasLength(1));
      expect(batchPosts, hasLength(1));
      sink.dispose();
    },
  );

  test(
    'retries failed frame uploads without dropping earlier frames',
    () async {
      frameStatus = 503;
      final sink = CollectorHttpSink(config: configForServer());
      final session = createSession();
      sink.startSession(session);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      sink.recordFrame(
        const TugboatFrame(
          id: 'frame-0',
          atMs: 0,
          width: 1,
          height: 1,
          contentHash: 'scroll-old',
          trigger: TugboatFrameTrigger.scroll,
        ),
        Uint8List.fromList([0]),
        sessionId: session.id,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      sink.recordFrame(
        const TugboatFrame(
          id: 'frame-1',
          atMs: 1,
          width: 1,
          height: 1,
          contentHash: 'tap-new',
          trigger: TugboatFrameTrigger.tap,
        ),
        Uint8List.fromList([1]),
        sessionId: session.id,
      );

      framePosts.clear();
      frameStatus = 202;
      await sink.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(framePosts, isNotEmpty);
      final uploadedNos = framePosts
          .expand((post) => (post['frameNos'] as List).cast<String>())
          .toSet();
      expect(uploadedNos.contains('0'), isTrue);
      expect(uploadedNos.contains('1'), isTrue);
      sink.dispose();
    },
  );

  test('skips duplicate session_start events in the event batch', () async {
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    sink.startSession(session);
    sink.recordEvent(
      TugboatEvent(id: 'event-start', atMs: 0, type: 'session_start'),
    );
    sink.recordEvent(createEvent(1));

    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(batchPosts, hasLength(1));
    expect(batchPosts.first, hasLength(1));
    expect(batchPosts.first.first['eventType'], 'capture_diagnostic');

    sink.dispose();
  });

  test('uploads frames as multipart form data', () async {
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    sink.startSession(session);

    sink.recordFrame(
      const TugboatFrame(
        id: 'frame-0',
        atMs: 0,
        width: 100,
        height: 200,
        contentHash: 'abc',
      ),
      Uint8List.fromList([1, 2, 3]),
      sessionId: session.id,
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(framePosts, hasLength(1));
    expect(framePosts.first['contentType'], 'multipart/form-data');

    sink.dispose();
  });

  test('keeps queued frames until collector session id is available', () async {
    sessionStatus = 503;
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    sink.startSession(session);

    sink.recordFrame(
      const TugboatFrame(
        id: 'frame-0',
        atMs: 0,
        width: 100,
        height: 200,
        contentHash: 'abc',
      ),
      Uint8List.fromList([1, 2, 3]),
      sessionId: session.id,
    );
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(framePosts, isEmpty);

    sessionStatus = 202;
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(framePosts, hasLength(1));
    expect(framePosts.single['frameNos'], ['0']);
    sink.dispose();
  });

  test(
    'does not requeue stale frame retries after a new session starts',
    () async {
      frameStatus = 503;
      frameResponseDelay = const Duration(milliseconds: 80);
      final sink = CollectorHttpSink(config: configForServer());
      final session = createSession();
      sink.startSession(session);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      sink.recordFrame(
        const TugboatFrame(
          id: 'frame-0',
          atMs: 0,
          width: 1,
          height: 1,
          contentHash: 'old',
        ),
        Uint8List.fromList([0]),
        sessionId: session.id,
      );
      while (framePosts.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final nextSession = createSession(id: 'session-new');
      sink.startSession(nextSession);
      framePosts.clear();
      frameStatus = 202;
      frameResponseDelay = Duration.zero;
      await Future<void>.delayed(const Duration(milliseconds: 140));

      sink.recordFrame(
        const TugboatFrame(
          id: 'frame-1',
          atMs: 1,
          width: 1,
          height: 1,
          contentHash: 'new',
        ),
        Uint8List.fromList([1]),
        sessionId: nextSession.id,
      );
      await sink.flush();

      expect(framePosts, hasLength(1));
      expect(framePosts.single['frameNos'], ['1']);
      sink.dispose();
    },
  );

  test(
    'sends collector context headers on JSON and multipart requests',
    () async {
      final sink = CollectorHttpSink(config: configForServer());
      final session = createSession();
      sink.startSession(session);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      sink.recordEvent(createEvent(0));
      await sink.flush();

      sink.recordFrame(
        const TugboatFrame(
          id: 'frame-0',
          atMs: 0,
          width: 100,
          height: 200,
          contentHash: 'abc',
        ),
        Uint8List.fromList([1, 2, 3]),
        sessionId: session.id,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expectCollectorHeaders(headersByPath['/v1/sessions']!.first);
      expectCollectorHeaders(headersByPath['/v1/events/batch']!.first);
      expectCollectorHeaders(headersByPath['/v1/frames']!.first);
      sink.dispose();
    },
  );

  test('includes frameMetadata on frame uploads', () async {
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    sink.startSession(session);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    sink.recordFrame(
      const TugboatFrame(
        id: 'frame-2',
        atMs: 5,
        width: 100,
        height: 200,
        contentHash: 'abc',
        requestedBackend: TugboatScreenshotCaptureBackend.nativeCpuExperimental,
        resolvedBackend: TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
        fallbackReason: 'native_unavailable',
        captureMicros: 12_000,
      ),
      Uint8List.fromList([1, 2, 3]),
      sessionId: session.id,
    );
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(framePosts, hasLength(1));
    final metadata = framePosts.single['frameMetadata'] as List<dynamic>;
    expect(metadata, hasLength(1));
    expect(metadata.single, {
      'id': 'frame-2',
      'atMs': 5,
      'width': 100,
      'height': 200,
      'contentHash': 'abc',
      'masked': false,
      'trigger': 'manual',
      'byteLength': 0,
      'captureMicros': 12_000,
      'requestedBackend': 'nativeCpuExperimental',
      'resolvedBackend': 'flutterRepaintBoundary',
      'fallbackReason': 'native_unavailable',
    });
    sink.dispose();
  });

  test('flush timer sends partial batches', () async {
    final sink = CollectorHttpSink(
      config: TugboatCollectorConfig(
        baseUrl: baseUri.toString(),
        apiKey: collectorConfig.apiKey,
        eventBatchSize: 10,
        eventFlushInterval: const Duration(milliseconds: 50),
        appInfo: collectorConfig.appInfo,
        deviceInfo: collectorConfig.deviceInfo,
        ipInfo: collectorConfig.ipInfo,
        locale: collectorConfig.locale,
      ),
    );
    final session = createSession();
    sink.startSession(session);
    sink.recordEvent(createEvent(1));
    sink.recordEvent(createEvent(2));

    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(batchPosts, isNotEmpty);
    expect(batchPosts.first.length, lessThan(10));

    sink.dispose();
  });

  test('endSession posts the final lifecycle event', () async {
    final sink = CollectorHttpSink(config: configForServer());
    sink.startSession(createSession());

    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sink.endSession();

    expect(sessionPosts.map((post) => post['eventType']), [
      'session_start',
      'session_end',
    ]);
    sink.dispose();
  });

  test(
    'a frame recorded during an in-flight flush is uploaded before session_end',
    () async {
      final sink = CollectorHttpSink(config: configForServer());
      final session = createSession();
      sink.startSession(session);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // A full batch starts a flush that is busy in its event loop.
      eventResponseDelay = const Duration(milliseconds: 150);
      for (var i = 0; i < 10; i++) {
        sink.recordEvent(createEvent(i));
      }
      while (batchPosts.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      // The session's last screenshot lands while that flush is running.
      sink.recordFrame(
        const TugboatFrame(
          id: 'frame-313',
          atMs: 313,
          width: 1,
          height: 1,
          contentHash: 'last',
        ),
        Uint8List.fromList([3]),
        sessionId: session.id,
      );
      await sink.endSession();

      expect(
        framePosts.expand((post) => post['frameNos'] as List),
        contains('313'),
      );
      expect(
        requestOrder,
        containsAllInOrder(['/v1/frames', '/v1/sessions:session_end']),
      );
      sink.dispose();
    },
  );

  test('a hung event post times out without blocking frame uploads', () async {
    final framePaths = <String>[];
    final eventIds = <String>[];
    var hangEvents = true;
    final sink = CollectorHttpSink(
      config: configForServer(),
      requestTimeout: const Duration(milliseconds: 100),
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/v1/sessions') {
          return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
        }
        if (path == '/v1/frames') {
          framePaths.add(path);
          return http.Response('{}', 202);
        }
        if (hangEvents) return Completer<http.Response>().future;
        final body = jsonDecode(request.body) as Map;
        eventIds.addAll([
          for (final event in body['events'] as List)
            (event as Map)['id'] as String,
        ]);
        return http.Response('{}', 202);
      }),
    );
    final session = createSession();
    sink.startSession(session);
    await sink.flush();

    for (var i = 0; i < 10; i++) {
      sink.recordEvent(createEvent(i));
    }
    recordTestFrame(sink, session, 1);
    await waitFor(() => framePaths.isNotEmpty);
    expect(framePaths, hasLength(1));

    hangEvents = false;
    await sink.flush();
    expect(eventIds, containsAll([for (var i = 0; i < 10; i++) 'event-$i']));
    sink.dispose();
  });

  test('a timed-out post is aborted instead of left open', () async {
    // A raw socket server answers session posts and never answers events, so
    // the test sees whether the client closes the hung connection.
    final rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final eventSocketClosed = Completer<void>();
    rawServer.listen((socket) {
      var carriesEventPost = false;
      socket.listen(
        (data) {
          final text = latin1.decode(data);
          if (text.startsWith('POST /v1/sessions')) {
            const body = '{"sessionId":"sess_server"}';
            socket.write(
              'HTTP/1.1 202 Accepted\r\n'
              'content-type: application/json\r\n'
              'content-length: ${body.length}\r\n\r\n$body',
            );
          } else if (text.startsWith('POST /v1/events/batch')) {
            carriesEventPost = true;
          }
        },
        onDone: () {
          if (carriesEventPost && !eventSocketClosed.isCompleted) {
            eventSocketClosed.complete();
          }
          socket.destroy();
        },
        onError: (Object _) {},
      );
    });
    baseUri = Uri.parse('http://127.0.0.1:${rawServer.port}');
    final sink = CollectorHttpSink(
      config: configForServer(),
      requestTimeout: const Duration(milliseconds: 100),
    );
    sink.startSession(createSession());
    await sink.flush();
    for (var i = 0; i < 10; i++) {
      sink.recordEvent(createEvent(i));
    }
    await sink.flush();

    // Without the abort the socket stays open until the sink is disposed.
    await expectLater(
      eventSocketClosed.future.timeout(const Duration(seconds: 2)),
      completes,
    );
    sink.dispose();
    await rawServer.close();
  });

  test('a hung session_start post times out and is retried', () async {
    var sessionPosts = 0;
    final frameNos = <String>[];
    final sink = CollectorHttpSink(
      config: configForServer(),
      requestTimeout: const Duration(milliseconds: 100),
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/v1/sessions') {
          sessionPosts += 1;
          if (sessionPosts == 1) return Completer<http.Response>().future;
          return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
        }
        if (path == '/v1/frames') {
          frameNos.addAll(
            RegExp(
              r'filename="(\d+)\.jpg"',
            ).allMatches(request.body).map((match) => match.group(1)!),
          );
        }
        return http.Response('{}', 202);
      }),
    );
    final session = createSession();
    sink.startSession(session);
    recordTestFrame(sink, session, 4);

    await waitFor(() => frameNos.isNotEmpty);
    expect(sessionPosts, 2);
    expect(frameNos, ['4']);
    sink.dispose();
  });

  test(
    'frames recorded during a long event drain go out between batches',
    () async {
      final sink = CollectorHttpSink(config: configForServer());
      final session = createSession();
      sink.startSession(session);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      eventResponseDelay = const Duration(milliseconds: 40);
      for (var i = 0; i < 30; i++) {
        sink.recordEvent(createEvent(i));
      }
      while (batchPosts.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      recordTestFrame(sink, session, 7);
      await sink.flush();

      final framesAt = requestOrder.indexOf('/v1/frames');
      expect(framesAt, isNonNegative);
      expect(framesAt, lessThan(requestOrder.lastIndexOf('/v1/events/batch')));
      expect(batchPosts.expand((batch) => batch), hasLength(30));
      sink.dispose();
    },
  );

  test('a slow flush reports the step it spent the most time in', () async {
    final sink = CollectorHttpSink(
      config: configForServer(),
      slowFlushThreshold: const Duration(milliseconds: 50),
    );
    sink.startSession(createSession());
    await sink.flush();

    eventResponseDelay = const Duration(milliseconds: 100);
    sink.recordEvent(createEvent(0));
    await sink.flush();
    eventResponseDelay = Duration.zero;
    await sink.flush();

    final slow = diagnosticsFor('collector_flush');
    expect(slow, hasLength(1));
    expect(slow.single['result'], 'slow');
    expect(slow.single['step'], 'events');
    expect(slow.single['durationMs'], greaterThanOrEqualTo(100));
    sink.dispose();
  });

  test(
    'a hung event post ends the pass and parks the rest for retry',
    () async {
      var hang = true;
      final batchesTriedWhileHung = <String>{};
      final delivered = <String>[];
      final sink = CollectorHttpSink(
        config: configForServer(),
        requestTimeout: const Duration(milliseconds: 50),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v1/sessions') {
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          if (path != '/v1/events/batch') return http.Response('{}', 202);
          final ids = [
            for (final event
                in (jsonDecode(request.body) as Map)['events'] as List)
              (event as Map)['id'] as String,
          ];
          if (hang) {
            batchesTriedWhileHung.add(ids.first);
            return Completer<http.Response>().future;
          }
          delivered.addAll(ids);
          return http.Response('{}', 202);
        }),
      );
      sink.startSession(createSession());
      await sink.flush();

      for (var i = 0; i < 50; i++) {
        sink.recordEvent(createEvent(i));
      }
      await sink.flush();
      // Only the first batch waited out a timeout; the other four were parked
      // unsent instead of each timing out in turn.
      expect(batchesTriedWhileHung.where((id) => id.startsWith('event-')), [
        'event-0',
      ]);

      hang = false;
      await sink.flush();
      expect(delivered.where((id) => id.startsWith('event-')), [
        for (var i = 0; i < 50; i++) 'event-$i',
      ]);
      sink.dispose();
    },
  );

  group('an event retry head with no response', () {
    ({CollectorHttpSink sink, List<String> delivered, List<String> heads})
    hangingSink({
      required bool Function(List<String> ids) hangs,
      int maxPendingBatches = 20,
    }) {
      final delivered = <String>[];
      final heads = <String>[];
      final sink = CollectorHttpSink(
        config: configForServer(maxPendingBatches: maxPendingBatches),
        requestTimeout: const Duration(milliseconds: 40),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v1/sessions') {
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          if (path != '/v1/events/batch') return http.Response('{}', 202);
          final ids = [
            for (final event
                in (jsonDecode(request.body) as Map)['events'] as List)
              (event as Map)['id'] as String,
          ];
          heads.add(ids.first);
          if (hangs(ids)) return Completer<http.Response>().future;
          delivered.addAll(ids);
          return http.Response('{}', 202);
        }),
      );
      return (sink: sink, delivered: delivered, heads: heads);
    }

    test('parks fresh events instead of posting them', () async {
      var hang = true;
      final run = hangingSink(hangs: (_) => hang);
      run.sink.startSession(createSession());
      await run.sink.flush();
      run.sink.recordEvent(createEvent(0));
      await run.sink.flush();
      run.heads.clear();

      for (var i = 1; i < 6; i++) {
        run.sink.recordEvent(createEvent(i));
      }
      await run.sink.flush();
      // Only the retry head went out; the fresh events did not wait out a
      // timeout of their own.
      expect(run.heads, ['event-0']);

      hang = false;
      await run.sink.flush();
      expect(run.delivered.where((id) => id.startsWith('event-')), [
        for (var i = 0; i < 6; i++) 'event-$i',
      ]);
      run.sink.dispose();
    });

    test('does not merge parked events into a short hanging head', () async {
      final run = hangingSink(
        hangs: (ids) => ids.contains('event-0'),
        maxPendingBatches: 2,
      );
      run.sink.startSession(createSession());
      await run.sink.flush();
      run.sink.recordEvent(createEvent(0));
      await run.sink.flush();
      for (var i = 1; i < 60; i++) {
        run.sink.recordEvent(createEvent(i));
        await run.sink.flush();
      }
      await run.sink.flush();
      await run.sink.flush();

      final delivered = run.delivered.where((id) => id.startsWith('event-'));
      expect(delivered, isNot(contains('event-0')));
      expect(delivered, containsAll([for (var i = 1; i < 9; i++) 'event-$i']));
      run.sink.dispose();
    });

    test('holds later events only until a hanging batch is evicted', () async {
      // The collector hangs on one batch only, and answers every other one.
      final run = hangingSink(
        hangs: (ids) => ids.contains('event-0'),
        maxPendingBatches: 2,
      );
      run.sink.startSession(createSession());
      await run.sink.flush();
      for (var i = 0; i < 10; i++) {
        run.sink.recordEvent(createEvent(i));
      }
      await run.sink.flush();
      for (var i = 10; i < 40; i++) {
        run.sink.recordEvent(createEvent(i));
        await run.sink.flush();
      }
      await run.sink.flush();
      await run.sink.flush();

      final delivered = run.delivered.where((id) => id.startsWith('event-'));
      expect(delivered, isNot(contains('event-0')));
      expect(
        delivered,
        containsAll([for (var i = 10; i < 40; i++) 'event-$i']),
      );
      run.sink.dispose();
    });
  });

  test(
    'events that arrive during a hung post do not evict parked batches',
    () async {
      var eventPosts = 0;
      final delivered = <String>[];
      late CollectorHttpSink sink;
      sink = CollectorHttpSink(
        config: configForServer(maxPendingBatches: 2, maxPendingEvents: 60),
        requestTimeout: const Duration(milliseconds: 50),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v1/sessions') {
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          if (path != '/v1/events/batch') return http.Response('{}', 202);
          eventPosts += 1;
          if (eventPosts == 1) {
            // Events keep arriving while the only hung post waits.
            Timer(const Duration(milliseconds: 10), () {
              for (var i = 20; i < 50; i++) {
                sink.recordEvent(createEvent(i));
              }
            });
            return Completer<http.Response>().future;
          }
          delivered.addAll([
            for (final event
                in (jsonDecode(request.body) as Map)['events'] as List)
              (event as Map)['id'] as String,
          ]);
          return http.Response('{}', 202);
        }),
      );
      sink.startSession(createSession());
      await sink.flush();

      for (var i = 0; i < 20; i++) {
        sink.recordEvent(createEvent(i));
      }
      await sink.flush();
      await sink.flush();
      expect(delivered.where((id) => id.startsWith('event-')), [
        for (var i = 0; i < 50; i++) 'event-$i',
      ]);
      sink.dispose();
    },
  );

  test(
    'a session started while the last one ends does not get its session_end',
    () async {
      final lifecycle = <String>[];
      final sink = CollectorHttpSink(
        config: configForServer(),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v1/sessions') {
            final body = jsonDecode(request.body) as Map;
            lifecycle.add('${body['eventType']}:${body['sessionId']}');
            return http.Response(
              jsonEncode({'sessionId': 'server-${body['sessionId']}'}),
              202,
            );
          }
          // Keep the ending session's flush busy long enough to restart.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response('{}', 202);
        }),
      );
      sink.startSession(createSession(id: 'first'));
      await sink.flush();
      sink.recordEvent(createEvent(0));

      final ending = sink.endSession();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      sink.startSession(createSession(id: 'second'));
      await ending;
      await sink.flush();

      expect(lifecycle, ['session_start:first', 'session_start:second']);
      sink.dispose();
    },
  );

  test('accepts empty 202 lifecycle body without retrying', () async {
    sessionResponseBody = '';
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    sink.startSession(session);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sessionPosts.map((post) => post['eventType']), ['session_start']);

    // Empty session_start body falls back to local session id for uploads.
    for (var i = 0; i < 10; i++) {
      sink.recordEvent(createEvent(i));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(batchPosts, hasLength(1));
    expect(batchPosts.first.first['sessionId'], session.id);

    await sink.endSession();
    expect(sessionPosts.map((post) => post['eventType']), [
      'session_start',
      'session_end',
    ]);

    final postsAfterEnd = sessionPosts.length;
    await sink.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sessionPosts, hasLength(postsAfterEnd));
    sink.dispose();
  });

  test('accepts non-JSON 202 lifecycle body without retrying', () async {
    sessionResponseBody = 'not-json';
    final sink = CollectorHttpSink(config: configForServer());
    sink.startSession(createSession());

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sessionPosts, hasLength(1));

    await sink.endSession();
    expect(sessionPosts.map((post) => post['eventType']), [
      'session_start',
      'session_end',
    ]);

    final postsAfterEnd = sessionPosts.length;
    await sink.flush();
    expect(sessionPosts, hasLength(postsAfterEnd));
    sink.dispose();
  });

  test('session lifecycle retries after transient failure', () async {
    sessionStatus = 503;
    final sink = CollectorHttpSink(config: configForServer());
    sink.startSession(createSession());

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sessionPosts.map((post) => post['eventType']), ['session_start']);
    expect(
      sessionPosts.where((post) => post['eventType'] == 'session_end'),
      isEmpty,
    );

    sessionStatus = 202;
    await sink.endSession();

    expect(sessionPosts.first['eventType'], 'session_start');
    expect(sessionPosts.last['eventType'], 'session_end');
    expect(
      sessionPosts.where((post) => post['eventType'] == 'session_start').length,
      greaterThanOrEqualTo(2),
    );
    sink.dispose();
  });

  test('session_start retries keep the initial locale', () async {
    sessionStatus = 503;
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession(
      locale: const TugboatLocaleInfo(
        language: 'en',
        country: 'US',
        tag: 'en-US',
      ),
    );
    sink.startSession(session);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    session.locale = const TugboatLocaleInfo(
      language: 'es',
      country: 'ES',
      tag: 'es-ES',
    );
    sessionStatus = 202;
    await sink.flush();

    final starts = sessionPosts.where(
      (post) => post['eventType'] == 'session_start',
    );
    expect(starts, hasLength(greaterThanOrEqualTo(2)));
    for (final start in starts) {
      expect(start['locale'], {
        'language': 'en',
        'country': 'US',
        'tag': 'en-US',
      });
    }
    sink.dispose();
  });

  test(
    'endSession drains session_end after session_start advances mid-drain',
    () async {
      sessionStatus = 503;
      final sink = CollectorHttpSink(config: configForServer());
      sink.startSession(createSession());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        sessionPosts.where((post) => post['eventType'] == 'session_start'),
        isNotEmpty,
      );

      // Fail endSession's first flush (session_start still pending), then allow
      // drain to accept start and continue on to session_end.
      sessionStatus = 202;
      sessionFailuresRemaining = 1;
      await sink.endSession();

      expect(
        sessionPosts.where((post) => post['eventType'] == 'session_end'),
        isNotEmpty,
      );
      expect(sessionPosts.last['eventType'], 'session_end');
      sink.dispose();
    },
  );

  test('recordFrame drops frames with a stale sessionId', () async {
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    sink.startSession(session);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    sink.recordFrame(
      const TugboatFrame(
        id: 'frame-0',
        atMs: 0,
        width: 1,
        height: 1,
        contentHash: 'hash-0',
      ),
      Uint8List.fromList([0]),
      sessionId: 'stale-session',
    );
    await sink.flush();

    expect(framePosts, isEmpty);
    sink.dispose();
  });

  test('fresh events flush even when retry head remains blocked', () async {
    eventStatus = 503;
    final sink = CollectorHttpSink(config: configForServer());
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    for (var i = 0; i < 10; i++) {
      sink.recordEvent(createEvent(i));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    batchPosts.clear();
    sink.recordEvent(createEvent(10));
    sink.recordEvent(createEvent(11));

    eventStatus = 202;
    await sink.flush();

    expect(batchPosts, hasLength(2));
    expect(batchPosts.first.map((event) => event['id']), [
      for (var i = 0; i < 10; i++) 'event-$i',
    ]);
    // The outage's collector_request diagnostics ride along with them.
    expect(
      batchPosts.last
          .map((event) => event['id'] as String)
          .where((id) => !id.startsWith('collector-request-')),
      ['event-10', 'event-11'],
    );
    sink.dispose();
  });

  test('event failures keep only a bounded in-memory tail', () async {
    eventStatus = 503;
    final sink = CollectorHttpSink(
      config: configForServer(maxPendingBatches: 1, maxPendingEvents: 12),
    );
    sink.startSession(createSession());

    for (var i = 0; i < 30; i++) {
      sink.recordEvent(createEvent(i));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    batchPosts.clear();
    eventStatus = 202;
    await sink.flush();

    final deliveredIds = [
      for (final batch in batchPosts)
        for (final event in batch) event['id'] as String,
    ];
    expect(deliveredIds, containsAll(['event-28', 'event-29']));
    expect(deliveredIds, isNot(contains('event-0')));
    expect(deliveredIds.length, lessThanOrEqualTo(22));
    sink.dispose();
  });

  test('frame failures keep only the configured in-memory tail', () async {
    frameStatus = 503;
    final sink = CollectorHttpSink(
      config: configForServer(maxPendingFrames: 3),
    );
    final session = createSession();
    sink.startSession(session);

    for (var i = 0; i < 5; i++) {
      sink.recordFrame(
        TugboatFrame(
          id: 'frame-$i',
          atMs: i,
          width: 1,
          height: 1,
          contentHash: 'hash-$i',
        ),
        Uint8List.fromList([i]),
        sessionId: session.id,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    framePosts.clear();
    frameStatus = 202;
    await sink.flush();

    expect(framePosts, hasLength(1));
    expect(framePosts.single['frameNos'], ['2', '3', '4']);
    sink.dispose();
  });

  test('frame eviction keeps frames that events reference', () async {
    sessionStatus = 503;
    final sink = CollectorHttpSink(
      config: configForServer(maxPendingFrames: 3),
    );
    final session = createSession();
    sink.startSession(session);
    for (var i = 0; i < 6; i++) {
      recordTestFrame(sink, session, i);
      if (i < 2) {
        sink.recordEvent(
          TugboatEvent(
            id: 'tap-$i',
            atMs: i,
            type: 'interaction',
            afterFrame: 'frame-$i',
          ),
        );
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));

    sessionStatus = 202;
    await sink.flush();

    expect(framePosts.expand((post) => post['frameNos'] as List), [
      '0',
      '1',
      '5',
    ]);
    sink.dispose();
  });

  test('frame references are forgotten once their frames leave', () async {
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    TugboatEvent tap(int frameNo) => TugboatEvent(
      id: 'tap-$frameNo-${DateTime.now().microsecondsSinceEpoch}',
      atMs: frameNo,
      type: 'interaction',
      afterFrame: 'frame-$frameNo',
    );
    sink.startSession(session);
    await sink.flush();

    for (var i = 0; i < 30; i++) {
      // An event can name its frame before the frame reaches the sink.
      sink.recordEvent(tap(i));
      recordTestFrame(sink, session, i);
    }
    await sink.flush();
    expect(sink.referencedFrameCount, 0);

    // And after the frame already went out.
    for (var i = 0; i < 30; i++) {
      sink.recordEvent(tap(i));
    }
    await sink.flush();
    expect(sink.referencedFrameCount, 0);
    sink.dispose();
  });

  test(
    'frames held during a backlog upload stay within one batch of the bound',
    () async {
      sessionStatus = 503;
      final sink = CollectorHttpSink(
        config: configForServer(maxPendingFrames: 40),
      );
      final session = createSession();
      sink.startSession(session);
      for (var i = 0; i < 40; i++) {
        recordTestFrame(sink, session, i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));

      sessionStatus = 202;
      frameResponseDelay = const Duration(milliseconds: 100);
      final draining = sink.flush();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      // A full bound of new frames arrives while the first batch uploads.
      for (var i = 40; i < 80; i++) {
        recordTestFrame(sink, session, i);
      }
      await draining;
      await sink.flush();
      await sink.flush();

      final sent = [
        for (final post in framePosts)
          for (final frameNo in post['frameNos'] as List) int.parse('$frameNo'),
      ];
      // Held at once: one batch in flight plus at most 40 pending.
      expect(sent.length, lessThanOrEqualTo(40 + 20));
      expect(sent, containsAll([for (var i = 40; i < 80; i++) i]));
      sink.dispose();
    },
  );

  test('pending frames are bounded by encoded bytes', () async {
    sessionStatus = 503;
    final sink = CollectorHttpSink(
      config: configForServer(maxPendingFrameBytes: 10),
    );
    final session = createSession();
    sink.startSession(session);
    for (var i = 0; i < 4; i++) {
      recordTestFrame(sink, session, i, byteLength: 4);
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));

    sessionStatus = 202;
    await sink.flush();

    expect(framePosts.expand((post) => post['frameNos'] as List), ['2', '3']);
    sink.dispose();
  });

  test(
    'default limits keep every referenced frame through a stall of 200 frames',
    () async {
      frameStatus = 503;
      final sink = CollectorHttpSink(
        config: TugboatCollectorConfig(
          baseUrl: baseUri.toString(),
          apiKey: collectorConfig.apiKey,
          eventFlushInterval: collectorConfig.eventFlushInterval,
          appInfo: collectorConfig.appInfo,
          deviceInfo: collectorConfig.deviceInfo,
          ipInfo: collectorConfig.ipInfo,
          locale: collectorConfig.locale,
        ),
      );
      final session = createSession();
      sink.startSession(session);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final referenced = <String>[];
      for (var i = 0; i < 200; i++) {
        recordTestFrame(sink, session, i, byteLength: 15 * 1024);
        if (i % 4 == 0) {
          referenced.add('$i');
          sink.recordEvent(
            TugboatEvent(
              id: 'tap-$i',
              atMs: i,
              type: 'interaction',
              afterFrame: 'frame-$i',
            ),
          );
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));

      frameStatus = 202;
      await sink.flush();
      await sink.flush();

      final uploaded = framePosts
          .where((post) => post['status'] == 202)
          .expand((post) => (post['frameNos'] as List).cast<String>())
          .toSet();
      expect(uploaded, containsAll(referenced));
      sink.dispose();
    },
  );

  test('session end reports the final dropped frame count', () async {
    frameStatus = 503;
    final sink = CollectorHttpSink(
      config: configForServer(maxPendingFrames: 3),
    );
    final session = createSession();
    sink.startSession(session);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (var i = 0; i < 8; i++) {
      recordTestFrame(sink, session, i);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await sink.endSession();

    final dropped = diagnosticsFor(
      'collector_frame_upload',
    ).where((payload) => payload['result'] == 'dropped').toList();
    expect(dropped, isNotEmpty);
    expect(dropped.last['droppedFrameCount'], 5);
    expect(sessionPosts.last['eventType'], 'session_end');
    sink.dispose();
  });

  test(
    'session and event post failures report once per outage and recovery',
    () async {
      sessionFailuresRemaining = 2;
      eventStatus = 502;
      final sink = CollectorHttpSink(config: configForServer());
      sink.startSession(createSession());
      await sink.flush();
      await sink.flush();
      await sink.flush();

      for (var i = 0; i < 20; i++) {
        sink.recordEvent(createEvent(i));
      }
      await sink.flush();
      eventStatus = 202;
      await sink.flush();
      await sink.flush();

      final diagnostics = diagnosticsFor('collector_request');
      expect(
        diagnostics.map(
          (payload) =>
              (payload['path'], payload['result'], payload['statusCode']),
        ),
        [
          ('/v1/sessions', 'failed', 503),
          ('/v1/sessions', 'recovered', null),
          ('/v1/events/batch', 'failed', 502),
          ('/v1/events/batch', 'recovered', null),
        ],
      );
      sink.dispose();
    },
  );

  test('a timed-out session post is reported as a timeout', () async {
    var sessionPosts = 0;
    final events = <Map<String, dynamic>>[];
    final sink = CollectorHttpSink(
      config: configForServer(),
      requestTimeout: const Duration(milliseconds: 50),
      client: MockClient((request) async {
        if (request.url.path == '/v1/sessions') {
          sessionPosts += 1;
          if (sessionPosts == 1) return Completer<http.Response>().future;
          return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
        }
        final body = jsonDecode(request.body) as Map;
        events.addAll([
          for (final event in body['events'] as List)
            Map<String, dynamic>.from(event as Map),
        ]);
        return http.Response('{}', 202);
      }),
    );
    sink.startSession(createSession());
    await waitFor(() => sessionPosts >= 2);
    await sink.flush();

    final failed = events
        .map((event) => event['payload'])
        .whereType<Map>()
        .where((payload) => payload['component'] == 'collector_request')
        .first;
    expect(failed['path'], '/v1/sessions');
    expect(failed['result'], 'failed');
    expect(failed['error'], 'timeout');
    expect(failed.containsKey('statusCode'), isFalse);
    sink.dispose();
  });

  test(
    'setTraits posts traits_updated, caches traitsId, stamps next events',
    () async {
      sessionResponseTraitsId = 'trt_abc';
      final sink = createIdentitySink(initialUserId: 'user_existing');
      final session = createSession();
      sink.startSession(session);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sessionPosts, hasLength(1));

      await sink.setTraits({'plan': 'pro', 'seatCount': 3});
      await awaitIdentityDebounce();
      expect(sessionPosts, hasLength(2));
      final traitsPost = sessionPosts.last;
      expect(traitsPost['eventType'], 'traits_updated');
      expect(traitsPost['traits'], {'plan': 'pro', 'seatCount': 3});
      expect(traitsPost['userId'], 'user_existing');
      expect(traitsPost.containsKey('traitsId'), isFalse);
      expect(traitsPost['sessionId'], 'sess_server');
      expect(sink.traitsId, 'trt_abc');

      sink.recordEvent(createEvent(0));
      await sink.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(batchPosts, isNotEmpty);
      expect(batchPosts.last.first['traitsId'], 'trt_abc');
      sink.dispose();
    },
  );

  test('session_start includes pre-set traits bag', () async {
    sessionResponseTraitsId = 'trt_from_start';
    final sink = CollectorHttpSink(
      config: configForServer(),
      initialTraits: {'plan': 'free'},
    );
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sessionPosts, hasLength(1));
    expect(sessionPosts.first['eventType'], 'session_start');
    expect(sessionPosts.first['traits'], {'plan': 'free'});
    expect(sessionPosts.first.containsKey('traitsId'), isFalse);
    expect(sink.traitsId, 'trt_from_start');
    sink.dispose();
  });

  test('setTraits before startSession lands on session_start', () async {
    sessionResponseTraitsId = 'trt_pre';
    final sink = CollectorHttpSink(config: configForServer());
    await sink.setTraits({'plan': 'starter'});
    expect(sessionPosts, isEmpty);

    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sessionPosts, hasLength(1));
    expect(sessionPosts.single['eventType'], 'session_start');
    expect(sessionPosts.single['traits'], {'plan': 'starter'});
    expect(
      sessionPosts.where((post) => post['eventType'] == 'traits_updated'),
      isEmpty,
    );
    sink.dispose();
  });

  test(
    'setTraits while session_start pending updates start payload only',
    () async {
      sessionStatus = 503;
      final sink = CollectorHttpSink(config: configForServer());
      sink.startSession(createSession());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Failed attempts are still recorded by the test server.
      expect(
        sessionPosts.where((post) => post['eventType'] == 'session_start'),
        isNotEmpty,
      );

      await sink.setTraits({'plan': 'pro'});
      expect(
        sessionPosts.where((post) => post['eventType'] == 'traits_updated'),
        isEmpty,
      );

      sessionStatus = 202;
      sessionResponseTraitsId = 'trt_pending';
      await sink.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final starts = sessionPosts
          .where((post) => post['eventType'] == 'session_start')
          .toList();
      expect(starts.last['traits'], {'plan': 'pro'});
      expect(
        sessionPosts.where((post) => post['eventType'] == 'traits_updated'),
        isEmpty,
      );
      sink.dispose();
    },
  );

  test(
    'new session_start includes traits bag after mid-session setTraits',
    () async {
      sessionResponseTraitsId = 'trt_mid';
      final sink = createIdentitySink();
      sink.startSession(createSession(id: 'session-a'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sessionPosts, hasLength(1));

      await sink.setTraits({'plan': 'pro'});
      await awaitIdentityDebounce();
      expect(sessionPosts, hasLength(2));
      expect(sessionPosts.last['eventType'], 'traits_updated');
      expect(sessionPosts.last['traits'], {'plan': 'pro'});

      await sink.endSession();
      sessionPosts.clear();

      sink.startSession(createSession(id: 'session-b'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sessionPosts.first['eventType'], 'session_start');
      expect(sessionPosts.first['traits'], {'plan': 'pro'});
      expect(sessionPosts.first.containsKey('traitsId'), isFalse);
      sink.dispose();
    },
  );

  test('session_end repeats cached traitsId and runtime userId', () async {
    final sink = CollectorHttpSink(
      config: configForServer(),
      initialTraitsId: 'trt_cached',
      initialUserId: 'user_end',
    );
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sessionPosts.first['eventType'], 'session_start');
    expect(sessionPosts.first['traitsId'], 'trt_cached');
    expect(sessionPosts.first['userId'], 'user_end');
    expect(sessionPosts.first.containsKey('traits'), isFalse);

    await sink.endSession();
    final endPost = sessionPosts.last;
    expect(endPost['eventType'], 'session_end');
    expect(endPost['userId'], 'user_end');
    expect(endPost['traitsId'], 'trt_cached');
    expect(endPost.containsKey('traits'), isFalse);
    sink.dispose();
  });

  test('setUserId posts user_changed with the current traits bag', () async {
    sessionResponseTraitsId = 'trt_user';
    final sink = createIdentitySink(
      initialTraits: {'plan': 'pro'},
      initialUserId: 'user_a',
    );
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await sink.setUserId('user_b');
    await awaitIdentityDebounce();
    expect(sink.userId, 'user_b');
    final changed = sessionPosts.last;
    expect(changed['eventType'], 'user_changed');
    expect(changed['userId'], 'user_b');
    expect(changed['traits'], {'plan': 'pro'});
    expect(changed.containsKey('traitsId'), isFalse);
    sink.dispose();
  });

  test('setUserId before startSession lands on session_start', () async {
    final sink = CollectorHttpSink(config: configForServer());
    await sink.setUserId('user_pre');
    expect(sessionPosts, isEmpty);
    expect(sink.userId, 'user_pre');

    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sessionPosts, hasLength(1));
    expect(sessionPosts.single['eventType'], 'session_start');
    expect(sessionPosts.single['userId'], 'user_pre');
    expect(
      sessionPosts.where((post) => post['eventType'] == 'user_changed'),
      isEmpty,
    );
    sink.dispose();
  });

  test(
    'setUserId while session_start pending updates start payload only',
    () async {
      sessionStatus = 503;
      final sink = CollectorHttpSink(config: configForServer());
      sink.startSession(createSession());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        sessionPosts.where((post) => post['eventType'] == 'session_start'),
        isNotEmpty,
      );

      await sink.setUserId('user_pending');
      expect(sink.userId, 'user_pending');
      expect(
        sessionPosts.where((post) => post['eventType'] == 'user_changed'),
        isEmpty,
      );

      sessionStatus = 202;
      await sink.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final starts = sessionPosts
          .where((post) => post['eventType'] == 'session_start')
          .toList();
      expect(starts.last['userId'], 'user_pending');
      expect(
        sessionPosts.where((post) => post['eventType'] == 'user_changed'),
        isEmpty,
      );
      sink.dispose();
    },
  );

  test('setUserId no-ops when user id is unchanged', () async {
    final sink = createIdentitySink(initialUserId: 'user_a');
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sessionPosts, hasLength(1));
    expect(sessionPosts.single['eventType'], 'session_start');

    await sink.setUserId('user_a');
    expect(sink.userId, 'user_a');
    expect(sessionPosts, hasLength(1));

    await sink.setUserId(null);
    await awaitIdentityDebounce();
    expect(sink.userId, isNull);
    expect(sessionPosts, hasLength(2));
    expect(sessionPosts.last['eventType'], 'user_changed');
    expect(sessionPosts.last['userId'], isNull);

    await sink.setUserId(null);
    expect(sessionPosts, hasLength(2));
    sink.dispose();
  });

  test('setTraits no-ops when traits bag is unchanged', () async {
    sessionResponseTraitsId = 'trt_skip';
    final sink = createIdentitySink();
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sessionPosts, hasLength(1));

    await sink.setTraits({'plan': 'pro'});
    await awaitIdentityDebounce();
    expect(sessionPosts, hasLength(2));
    expect(sessionPosts.last['eventType'], 'traits_updated');
    expect(sessionPosts.last['traits'], {'plan': 'pro'});

    await sink.setTraits({'plan': 'pro'});
    expect(sessionPosts, hasLength(2));

    await sink.setTraits({'plan': 'enterprise'});
    await awaitIdentityDebounce();
    expect(sessionPosts, hasLength(3));
    expect(sessionPosts.last['eventType'], 'traits_updated');
    expect(sessionPosts.last['traits'], {'plan': 'enterprise'});
    sink.dispose();
  });

  test(
    'setUserId then setTraits within debounce posts session_identify once',
    () async {
      sessionResponseTraitsId = 'trt_both';
      final sink = createIdentitySink();
      sink.startSession(createSession());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sessionPosts, hasLength(1));

      await sink.setUserId('user_coalesce');
      await sink.setTraits({'plan': 'pro', 'seatCount': 2});
      await awaitIdentityDebounce();

      expect(sessionPosts, hasLength(2));
      expect(sessionPosts.last['eventType'], 'session_identify');
      expect(sessionPosts.last['userId'], 'user_coalesce');
      expect(sessionPosts.last['traits'], {'plan': 'pro', 'seatCount': 2});
      expect(
        sessionPosts.where((post) => post['eventType'] == 'user_changed'),
        isEmpty,
      );
      expect(
        sessionPosts.where((post) => post['eventType'] == 'traits_updated'),
        isEmpty,
      );
      sink.dispose();
    },
  );

  test('debounced identity uses first dirty time as triggeredAt', () async {
    final sink = createIdentitySink();
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final before = DateTime.now();
    await sink.setTraits({'plan': 'pro'});
    final afterCall = DateTime.now();
    await awaitIdentityDebounce();
    final afterDebounce = DateTime.now();

    expect(sessionPosts, hasLength(2));
    expect(sessionPosts.last['eventType'], 'traits_updated');
    final triggeredAt = DateTime.parse(
      sessionPosts.last['triggeredAt'] as String,
    );
    expect(
      triggeredAt.isAfter(before.subtract(const Duration(milliseconds: 50))),
      isTrue,
    );
    expect(
      triggeredAt.isBefore(afterCall.add(const Duration(milliseconds: 50))),
      isTrue,
    );
    expect(
      triggeredAt.isBefore(
        afterDebounce.subtract(const Duration(milliseconds: 20)),
      ),
      isTrue,
    );
    sink.dispose();
  });

  test('debounced user change keeps its dirty time as triggeredAt', () async {
    final sink = createIdentitySink();
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final before = DateTime.now();
    await sink.setUserId('user_at');
    final afterCall = DateTime.now();
    await awaitIdentityDebounce();
    final afterDebounce = DateTime.now();

    expect(sessionPosts, hasLength(2));
    expect(sessionPosts.last['eventType'], 'user_changed');
    final triggeredAt = DateTime.parse(
      sessionPosts.last['triggeredAt'] as String,
    );
    expect(
      triggeredAt.isAfter(before.subtract(const Duration(milliseconds: 50))),
      isTrue,
    );
    expect(
      triggeredAt.isBefore(afterCall.add(const Duration(milliseconds: 50))),
      isTrue,
    );
    expect(
      triggeredAt.isBefore(
        afterDebounce.subtract(const Duration(milliseconds: 20)),
      ),
      isTrue,
    );
    sink.dispose();
  });

  test(
    'coalesced identity uses the later user dirty time when traits change first',
    () async {
      final sink = createIdentitySink();
      sink.startSession(createSession());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await sink.setTraits({'plan': 'pro'});
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final beforeUser = DateTime.now();
      await sink.setUserId('user_at');
      final afterUser = DateTime.now();
      await awaitIdentityDebounce();

      expect(sessionPosts.last['eventType'], 'session_identify');
      final triggeredAt = DateTime.parse(
        sessionPosts.last['triggeredAt'] as String,
      );
      expect(
        triggeredAt.isAfter(
          beforeUser.subtract(const Duration(milliseconds: 50)),
        ),
        isTrue,
      );
      expect(
        triggeredAt.isBefore(afterUser.add(const Duration(milliseconds: 50))),
        isTrue,
      );
      sink.dispose();
    },
  );

  test('endSession flushes debounced identity before session_end', () async {
    sessionResponseTraitsId = 'trt_end';
    final sink = createIdentitySink();
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await sink.setTraits({'plan': 'pro'});
    expect(sessionPosts, hasLength(1));

    await sink.endSession();
    expect(sessionPosts.map((post) => post['eventType']), [
      'session_start',
      'traits_updated',
      'session_end',
    ]);
    expect(sessionPosts.last['userId'], isNull);
    expect(sessionPosts.last['traits'], {'plan': 'pro'});
    sink.dispose();
  });

  group('rejected lifecycle posts', () {
    Future<List<String>> run({required String rejectOnce}) async {
      final eventTypes = <String>[];
      var rejected = false;
      final sink = CollectorHttpSink(
        config: configForServer(),
        identityDebounceDuration: const Duration(milliseconds: 1),
        client: MockClient((request) async {
          if (request.url.path != '/v1/sessions') {
            return http.Response('{}', 202);
          }
          final type = (jsonDecode(request.body) as Map)['eventType'] as String;
          eventTypes.add(type);
          if (type == rejectOnce && !rejected) {
            rejected = true;
            return http.Response('{}', 400);
          }
          return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
        }),
      );
      sink.startSession(createSession());
      await sink.flush();
      await sink.flush();
      await sink.setUserId('user-1');
      await sink.endSession();
      sink.dispose();
      return eventTypes;
    }

    test('a rejected identity post does not hold session_end', () async {
      expect(await run(rejectOnce: 'user_changed'), [
        'session_start',
        'user_changed',
        'session_end',
      ]);
    });

    test('a rejected session_start is kept and retried', () async {
      expect(await run(rejectOnce: 'session_start'), [
        'session_start',
        'session_start',
        'user_changed',
        'session_end',
      ]);
    });

    test('do not keep the slow-flush report switched off', () async {
      var eventsHang = false;
      final delivered = <Map>[];
      final sink = CollectorHttpSink(
        config: configForServer(),
        requestTimeout: const Duration(milliseconds: 40),
        slowFlushThreshold: const Duration(milliseconds: 30),
        identityDebounceDuration: const Duration(milliseconds: 1),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v1/sessions') {
            if (request.body.contains('user_changed')) {
              return http.Response('{}', 400);
            }
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          if (path != '/v1/events/batch') return http.Response('{}', 202);
          if (eventsHang) return Completer<http.Response>().future;
          delivered.addAll(
            ((jsonDecode(request.body) as Map)['events'] as List).cast<Map>(),
          );
          return http.Response('{}', 202);
        }),
      );
      sink.startSession(createSession());
      await sink.flush();
      await sink.setUserId('user-1');
      await sink.flush();
      // Two separate event outages each report one slow flush.
      for (final index in [0, 1]) {
        sink.recordEvent(createEvent(index));
        eventsHang = true;
        for (var pass = 0; pass < 3; pass++) {
          await sink.flush();
        }
        eventsHang = false;
        for (var pass = 0; pass < 5; pass++) {
          await sink.flush();
        }
      }
      final slowIds = {
        for (final event in delivered)
          if ((event['payload'] as Map?)?['component'] == 'collector_flush')
            event['id'],
      };
      expect(slowIds, hasLength(2));
      sink.dispose();
    });
  });

  group('slow-flush diagnostics during an outage', () {
    Future<({List<String> realIds, int slowReports})> runOutage({
      required bool flaky,
    }) async {
      var outage = true;
      var eventPosts = 0;
      final delivered = <Map>[];
      final sink = CollectorHttpSink(
        config: configForServer(),
        requestTimeout: const Duration(milliseconds: 30),
        slowFlushThreshold: const Duration(milliseconds: 20),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v1/sessions') {
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          if (path != '/v1/events/batch') return http.Response('{}', 202);
          if (outage) {
            eventPosts += 1;
            // A flaky network mixes hangs with instant failures.
            if (flaky && eventPosts.isEven) return http.Response('{}', 503);
            return Completer<http.Response>().future;
          }
          final body = jsonDecode(request.body) as Map;
          delivered.addAll((body['events'] as List).cast<Map>());
          return http.Response('{}', 202);
        }),
      );
      sink.startSession(createSession());
      await sink.flush();
      for (var i = 0; i < 3; i++) {
        sink.recordEvent(createEvent(i));
      }
      for (var pass = 0; pass < 40; pass++) {
        await sink.flush();
      }
      outage = false;
      for (var pass = 0; pass < 5; pass++) {
        await sink.flush();
      }
      sink.dispose();
      return (
        realIds: [
          for (final event in delivered)
            if ('${event['id']}'.startsWith('event-')) '${event['id']}',
        ],
        slowReports: delivered
            .where(
              (event) =>
                  (event['payload'] as Map?)?['component'] == 'collector_flush',
            )
            .length,
      );
    }

    test('are reported once and do not evict real events', () async {
      final result = await runOutage(flaky: false);
      expect(result.realIds, ['event-0', 'event-1', 'event-2']);
      expect(result.slowReports, 1);
    });

    test('stay reported once when fast failures mix with hangs', () async {
      final result = await runOutage(flaky: true);
      expect(result.realIds, ['event-0', 'event-1', 'event-2']);
      expect(result.slowReports, 1);
    });
  });

  group('lifecycle durations ignore wall-clock changes', () {
    final startedAt = DateTime.utc(2026, 6, 19);
    final jumps = {
      'back a day': const Duration(days: -1),
      'forward a day': const Duration(days: 1),
    };

    ({CollectorHttpSink sink, List<Map<String, dynamic>> sessions}) build({
      required DateTime Function() wallClock,
      required _FakeStopwatch watch,
      List<Map<String, dynamic>>? batches,
      Duration identityDebounce = const Duration(hours: 1),
    }) {
      final sessions = <Map<String, dynamic>>[];
      final sink = CollectorHttpSink(
        config: collectorConfig,
        wallClock: wallClock,
        stopwatchFactory: () => watch,
        identityDebounceDuration: identityDebounce,
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path == '/v1/sessions') {
            sessions.add(body);
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          batches?.addAll([
            for (final event in body['events'] as List)
              Map<String, dynamic>.from(event as Map),
          ]);
          return http.Response('{}', 202);
        }),
      );
      return (sink: sink, sessions: sessions);
    }

    for (final jump in jumps.entries) {
      test(
        'session_end keeps its duration when the clock jumps ${jump.key}',
        () async {
          var wall = startedAt;
          final watch = _FakeStopwatch();
          final built = build(wallClock: () => wall, watch: watch);
          final sink = built.sink;
          sink.startSession(createSession());
          await sink.flush();

          watch.time = const Duration(seconds: 5);
          wall = startedAt.add(const Duration(seconds: 5) + jump.value);
          await sink.endSession();

          final end = built.sessions.last;
          expect(end['eventType'], 'session_end');
          expect(end['atMs'], 5000);
          // Absolute timestamps still come from the wall clock.
          expect(end['triggeredAt'], wall.toIso8601String());
          sink.dispose();
        },
      );
    }

    test('session_start stays at atMs 0', () async {
      final watch = _FakeStopwatch()..time = const Duration(seconds: 2);
      final built = build(
        wallClock: () => startedAt.add(const Duration(days: 3)),
        watch: watch,
      );
      built.sink.startSession(createSession());
      await built.sink.flush();

      expect(built.sessions.first['eventType'], 'session_start');
      expect(built.sessions.first['atMs'], 0);
      expect(built.sessions.first['triggeredAt'], startedAt.toIso8601String());
      built.sink.dispose();
    });

    test(
      'a coalesced identity update uses the later trigger by elapsed time',
      () async {
        var wall = startedAt;
        final watch = _FakeStopwatch();
        final built = build(
          wallClock: () => wall,
          watch: watch,
          identityDebounce: const Duration(milliseconds: 30),
        );
        final sink = built.sink;
        sink.startSession(createSession());
        await sink.flush();

        watch.time = const Duration(seconds: 1);
        wall = startedAt.add(const Duration(hours: 5));
        await sink.setTraits({'plan': 'pro'});
        // The user change comes later, but the wall clock was set back before it.
        watch.time = const Duration(seconds: 2);
        wall = startedAt.add(const Duration(hours: 1));
        await sink.setUserId('user_at');
        watch.time = const Duration(seconds: 4);
        await waitFor(() => built.sessions.length >= 2);

        final identify = built.sessions.last;
        expect(identify['eventType'], 'session_identify');
        expect(identify['atMs'], 2000);
        expect(
          identify['triggeredAt'],
          startedAt.add(const Duration(hours: 1)).toIso8601String(),
        );
        sink.dispose();
      },
    );

    test('capture_diagnostic atMs comes from the session stopwatch', () async {
      var accept = false;
      final events = <Map<String, dynamic>>[];
      final watch = _FakeStopwatch();
      var wall = startedAt;
      final sink = CollectorHttpSink(
        config: collectorConfig,
        wallClock: () => wall,
        stopwatchFactory: () => watch,
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path == '/v1/sessions') {
            return accept
                ? http.Response(jsonEncode({'sessionId': 'sess_server'}), 202)
                : http.Response('', 503);
          }
          events.addAll([
            for (final event in body['events'] as List)
              Map<String, dynamic>.from(event as Map),
          ]);
          return http.Response('{}', 202);
        }),
      );
      sink.startSession(createSession());
      watch.time = const Duration(seconds: 3);
      wall = startedAt.add(const Duration(days: 1));
      await sink.flush();
      accept = true;
      await sink.flush();
      await sink.flush();

      final failed = events.firstWhere(
        (event) =>
            (event['payload'] as Map)['component'] == 'collector_request' &&
            (event['payload'] as Map)['result'] == 'failed',
      );
      expect(failed['atMs'], 3000);
      sink.dispose();
    });
  });

  group('sink health reflects what the collector sink holds', () {
    TugboatFrame frameFor(int frameNo) => TugboatFrame(
      id: 'frame-$frameNo',
      atMs: frameNo,
      width: 1,
      height: 1,
      contentHash: 'hash-$frameNo',
    );

    test('events in a stalled request count as pending', () async {
      final stalled = Completer<http.Response>();
      var eventPosts = 0;
      final sink = CollectorHttpSink(
        config: collectorConfig,
        client: MockClient((request) async {
          if (request.url.path == '/v1/sessions') {
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          eventPosts += 1;
          return stalled.future;
        }),
      );
      final hub = TugboatCaptureSinkHub([sink]);
      hub.startSession(createSession());
      await sink.flush();

      for (var i = 0; i < 10; i++) {
        hub.recordEvent(createEvent(i));
      }
      await waitFor(() => eventPosts > 0);
      expect(hub.acceptCount, 10);
      expect(hub.pendingCount, 10);
      expect(hub.dropCount, 0);

      stalled.complete(http.Response('{}', 202));
      await sink.flush();
      expect(hub.pendingCount, 0);
      sink.dispose();
    });

    test('frames in a stalled upload count as pending', () async {
      final stalled = Completer<http.Response>();
      var frameRequests = 0;
      final sink = CollectorHttpSink(
        config: collectorConfig,
        client: MockClient((request) async {
          if (request.url.path == '/v1/sessions') {
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          if (request.url.path == '/v1/frames') {
            frameRequests += 1;
            return stalled.future;
          }
          return http.Response('{}', 202);
        }),
      );
      final hub = TugboatCaptureSinkHub([sink]);
      final session = createSession();
      hub.startSession(session);
      await sink.flush();

      for (var i = 0; i < 3; i++) {
        hub.recordFrame(frameFor(i), Uint8List(1), sessionId: session.id);
      }
      await waitFor(() => frameRequests > 0);
      expect(hub.pendingCount, 3);
      expect(hub.dropCount, 0);

      stalled.complete(http.Response('{}', 202));
      await sink.flush();
      expect(hub.pendingCount, 0);
      sink.dispose();
    });

    test('events dropped at the pending cap are counted', () async {
      final sink = CollectorHttpSink(
        config: configForServer(maxPendingEvents: 5),
        client: MockClient((request) async => http.Response('', 503)),
      );
      final hub = TugboatCaptureSinkHub([sink]);
      hub.startSession(createSession());
      // The failed session_start queues one collector_request diagnostic.
      await sink.flush();
      final queued = hub.pendingCount;

      for (var i = 0; i < 10; i++) {
        hub.recordEvent(createEvent(i));
      }

      expect(hub.pendingCount, 5);
      expect(hub.dropCount, queued + 10 - 5);
      sink.dispose();
    });

    test('events evicted from the retry queue are counted', () async {
      final sink = CollectorHttpSink(
        config: configForServer(maxPendingBatches: 1),
        client: MockClient((request) async {
          if (request.url.path == '/v1/sessions') {
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          return http.Response('', 503);
        }),
      );
      final hub = TugboatCaptureSinkHub([sink]);
      hub.startSession(createSession());
      await sink.flush();

      for (var i = 0; i < 30; i++) {
        hub.recordEvent(createEvent(i));
      }
      for (var pass = 0; pass < 3; pass++) {
        await sink.flush();
      }

      // Nothing is delivered and the retry queue holds a single batch, so most
      // of the 30 events are evicted and counted. The sink also queues its own
      // diagnostics, which can push a batch out as well, so only lower bounds
      // are asserted here.
      expect(hub.dropCount, greaterThanOrEqualTo(20));
      expect(hub.pendingCount + hub.dropCount, greaterThanOrEqualTo(30));
      sink.dispose();
    });

    test('frames evicted at the frame cap are counted', () async {
      final sink = CollectorHttpSink(
        config: configForServer(maxPendingFrames: 3),
        client: MockClient((request) async => http.Response('', 503)),
      );
      final hub = TugboatCaptureSinkHub([sink]);
      final session = createSession();
      hub.startSession(session);
      await sink.flush();
      final queued = hub.pendingCount;

      for (var i = 0; i < 5; i++) {
        hub.recordFrame(frameFor(i), Uint8List(1), sessionId: session.id);
      }

      // Each of the two evictions also queued a `dropped` diagnostic event.
      expect(hub.pendingCount, queued + 3 + 2);
      expect(hub.dropCount, 2);
      sink.dispose();
    });

    test('the drop count survives a new session', () async {
      final sink = CollectorHttpSink(
        config: configForServer(maxPendingFrames: 1),
        client: MockClient((request) async => http.Response('', 503)),
      );
      final hub = TugboatCaptureSinkHub([sink]);
      final session = createSession();
      hub.startSession(session);
      for (var i = 0; i < 3; i++) {
        hub.recordFrame(frameFor(i), Uint8List(1), sessionId: session.id);
      }
      expect(hub.dropCount, 2);
      // The kept frame and the drop diagnostics are still queued; the new
      // session clears them and counts them as dropped on top.
      final queued = hub.pendingCount;
      expect(queued, greaterThan(0));

      hub.startSession(createSession(id: 'session-next'));
      expect(hub.dropCount, 2 + queued);
      sink.dispose();
    });
  });

  group('backlog cleared by a new session or dispose', () {
    TugboatFrame frameFor(int frameNo) => TugboatFrame(
      id: 'frame-$frameNo',
      atMs: frameNo,
      width: 1,
      height: 1,
      contentHash: 'hash-$frameNo',
    );

    /// A sink whose posts to [stallPath] (after [failFirst] 503s) wait on the
    /// returned completer. Every other request is accepted.
    ({
      CollectorHttpSink sink,
      Completer<http.Response> stalled,
      int Function() stalledPosts,
    })
    stallingSink(String stallPath, {int failFirst = 0}) {
      final stalled = Completer<http.Response>();
      var posts = 0;
      var failures = failFirst;
      final sink = CollectorHttpSink(
        config: collectorConfig,
        client: MockClient((request) async {
          if (request.url.path == '/v1/sessions') {
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          if (request.url.path != stallPath) return http.Response('{}', 202);
          if (failures > 0) {
            failures -= 1;
            return http.Response('', 503);
          }
          posts += 1;
          return stalled.future;
        }),
      );
      return (sink: sink, stalled: stalled, stalledPosts: () => posts);
    }

    for (final release in {'delivered': 202, 'left to retry': 503}.entries) {
      final delivered = release.value == 202;

      test('a new session counts queued events as dropped; a stalled request '
          '${release.key} settles its own events', () async {
        final built = stallingSink('/v1/events/batch');
        final sink = built.sink;
        final hub = TugboatCaptureSinkHub([sink]);
        hub.startSession(createSession());
        await sink.flush();
        for (var i = 0; i < 10; i++) {
          hub.recordEvent(createEvent(i));
        }
        await waitFor(() => built.stalledPosts() > 0);
        for (var i = 10; i < 13; i++) {
          hub.recordEvent(createEvent(i));
        }
        expect(hub.pendingCount, 13);
        expect(hub.dropCount, 0);

        hub.startSession(createSession(id: 'session-next'));
        // The 3 queued events are gone; the 10 in the request may still land.
        expect(hub.pendingCount, 10);
        expect(hub.dropCount, 3);

        built.stalled.complete(http.Response('{}', release.value));
        await waitFor(() => hub.pendingCount == 0);
        await sink.flush();
        expect(sink.pendingCount, 0);
        expect(hub.dropCount, delivered ? 3 : 13);
        sink.dispose();
      });

      test('a retry head in a stalled request is not counted twice when it '
          'is ${release.key}', () async {
        final built = stallingSink('/v1/events/batch', failFirst: 1);
        final sink = built.sink;
        final hub = TugboatCaptureSinkHub([sink]);
        hub.startSession(createSession());
        await sink.flush();
        for (var i = 0; i < 10; i++) {
          hub.recordEvent(createEvent(i));
        }
        // The batch fails once and waits in the retry queue.
        await waitFor(() => hub.pendingCount > 10);
        // The retry head goes out again and stalls.
        unawaited(sink.flush());
        await waitFor(() => built.stalledPosts() > 0);
        final pendingBefore = hub.pendingCount;
        expect(pendingBefore, greaterThan(10));
        expect(hub.dropCount, 0);

        hub.startSession(createSession(id: 'session-next'));
        // Only what was queued (the failure diagnostic) is dropped; the head
        // is still in its request.
        expect(hub.pendingCount, 10);
        expect(hub.dropCount, pendingBefore - 10);

        built.stalled.complete(http.Response('{}', release.value));
        await waitFor(() => hub.pendingCount == 0);
        await sink.flush();
        expect(sink.pendingCount, 0);
        expect(hub.dropCount, delivered ? pendingBefore - 10 : pendingBefore);
        sink.dispose();
      });

      test('dispose counts queued items as dropped; a stalled frame upload '
          '${release.key} settles its own frames', () async {
        final built = stallingSink('/v1/frames');
        final sink = built.sink;
        final session = createSession();
        sink.startSession(session);
        await sink.flush();
        for (var i = 0; i < 3; i++) {
          sink.recordFrame(frameFor(i), Uint8List(1), sessionId: session.id);
        }
        await waitFor(() => built.stalledPosts() > 0);
        for (var i = 0; i < 2; i++) {
          sink.recordEvent(createEvent(i));
        }
        expect(sink.pendingCount, 5);
        expect(sink.droppedCount, 0);

        sink.dispose();
        expect(sink.pendingCount, 3);
        expect(sink.droppedCount, 2);

        built.stalled.complete(http.Response('{}', release.value));
        await waitFor(() => sink.pendingCount == 0);
        expect(sink.pendingCount, 0);
        expect(sink.droppedCount, delivered ? 2 : 5);
      });
    }

    test('dispose with a stalled event request never reads negative', () async {
      final built = stallingSink('/v1/events/batch');
      final sink = built.sink;
      sink.startSession(createSession());
      await sink.flush();
      for (var i = 0; i < 10; i++) {
        sink.recordEvent(createEvent(i));
      }
      await waitFor(() => built.stalledPosts() > 0);
      sink.recordEvent(createEvent(10));

      sink.dispose();
      expect(sink.pendingCount, 10);
      expect(sink.droppedCount, 1);

      built.stalled.complete(http.Response('{}', 202));
      await waitFor(() => sink.pendingCount == 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sink.pendingCount, 0);
      expect(sink.droppedCount, 1);
    });

    test('frames requeued after a 5xx are not counted twice', () async {
      var frameFailures = 1;
      final sink = CollectorHttpSink(
        config: collectorConfig,
        client: MockClient((request) async {
          if (request.url.path == '/v1/sessions') {
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          if (request.url.path == '/v1/frames' && frameFailures > 0) {
            frameFailures -= 1;
            return http.Response('', 503);
          }
          return http.Response('{}', 202);
        }),
      );
      final hub = TugboatCaptureSinkHub([sink]);
      final session = createSession();
      hub.startSession(session);
      await sink.flush();
      for (var i = 0; i < 3; i++) {
        hub.recordFrame(frameFor(i), Uint8List(1), sessionId: session.id);
      }
      await waitFor(() => frameFailures == 0);
      await sink.flush();
      expect(hub.dropCount, 0);

      await sink.flush();
      await sink.flush();
      expect(hub.pendingCount, 0);
      expect(hub.dropCount, 0);
      sink.dispose();
    });
  });

  group('lifecycle atMs shares the controller clock', () {
    test('session_end is not before the last event when the sink starts '
        'late', () async {
      final startedAt = DateTime.utc(2026, 6, 19);
      final watch = _FakeStopwatch();
      final sessions = <Map<String, dynamic>>[];
      final events = <Map<String, dynamic>>[];
      final sink = CollectorHttpSink(
        config: collectorConfig,
        // The controller stamped startedAt and started its clock 250 ms
        // before the sink's startSession (listeners, sink factories).
        wallClock: () => startedAt.add(const Duration(milliseconds: 250)),
        stopwatchFactory: () => watch,
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path == '/v1/sessions') {
            sessions.add(body);
            return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
          }
          events.addAll([
            for (final event in body['events'] as List)
              Map<String, dynamic>.from(event as Map),
          ]);
          return http.Response('{}', 202);
        }),
      );
      sink.startSession(createSession());
      await sink.flush();

      // The controller clock now reads 1250 ms; the sink's stopwatch 1000 ms.
      watch.time = const Duration(seconds: 1);
      sink.recordEvent(
        const TugboatEvent(id: 'last', atMs: 1250, type: 'tap', data: {}),
      );
      await sink.endSession();

      final end = sessions.last;
      expect(end['eventType'], 'session_end');
      final lastEvent = events.last;
      expect(end['atMs'], greaterThanOrEqualTo(lastEvent['atMs'] as int));
      expect(end['atMs'], 1250);
      expect(sessions.first['atMs'], 0);
      sink.dispose();
    });
  });
}
