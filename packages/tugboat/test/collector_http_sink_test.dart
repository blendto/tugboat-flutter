import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_http_sink.dart';
import 'package:tugboat/src/models.dart';
import 'package:tugboat/src/sdk_version.dart';

void main() {
  late HttpServer server;
  late Uri baseUri;
  final sessionPosts = <Map<String, dynamic>>[];
  final batchPosts = <List<Map<String, dynamic>>>[];
  final framePosts = <Map<String, dynamic>>[];
  final headersByPath = <String, List<Map<String, String?>>>{};
  var eventStatus = 202;
  var frameStatus = 202;
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
    headersByPath.clear();
    eventStatus = 202;
    frameStatus = 202;
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
        final contentType = request.headers.contentType;
        final boundary = contentType?.parameters['boundary'];
        expect(boundary, isNotNull);
        final bodyBytes = await request.fold<BytesBuilder>(
          BytesBuilder(),
          (builder, data) => builder..add(data),
        );
        final bytes = bodyBytes.takeBytes();
        final encodedBody = latin1.decode(bytes);
        framePosts.add({
          'contentType': contentType?.mimeType,
          'bytes': bytes,
          'frameNos': RegExp(
            r'filename="(\d+)\.jpg"',
          ).allMatches(encodedBody).map((match) => match.group(1)).toList(),
        });
        if (frameResponseDelay > Duration.zero) {
          await Future<void>.delayed(frameResponseDelay);
        }
        request.response
          ..statusCode = frameStatus
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
  }) {
    return TugboatCollectorConfig(
      baseUrl: baseUri.toString(),
      apiKey: collectorConfig.apiKey,
      eventBatchSize: collectorConfig.eventBatchSize,
      eventFlushInterval: collectorConfig.eventFlushInterval,
      maxPendingBatches: maxPendingBatches,
      maxPendingEvents: maxPendingEvents,
      maxPendingFrames: maxPendingFrames,
      appInfo: collectorConfig.appInfo,
      deviceInfo: collectorConfig.deviceInfo,
      ipInfo: collectorConfig.ipInfo,
      locale: collectorConfig.locale,
    );
  }

  TugboatSession createSession({String id = 'session-local'}) {
    return TugboatSession(
      id: id,
      startedAt: DateTime.utc(2026, 6, 19),
      platform: 'ios',
      viewport: const TugboatRect(0, 0, 390, 844),
    );
  }

  TugboatEvent createEvent(int index) {
    return TugboatEvent(
      id: 'event-$index',
      atMs: index,
      type: 'tap',
      data: {'index': index},
    );
  }

  void expectCollectorHeaders(Map<String, String?> headers) {
    expect(headers['X-Platform'], collectorConfig.deviceInfo.platform);
    expect(headers['X-App-Build'], collectorConfig.appInfo.buildNumber);
    expect(headers['X-App-Version'], collectorConfig.appInfo.version);
    expect(headers['X-App-Id'], collectorConfig.appInfo.appId);
    expect(headers['X-Sdk-Version'], tugboatSdkVersion);
  }

  Future<void> awaitIdentityDebounce() async {
    await Future<void>.delayed(const Duration(milliseconds: 3100));
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

  test('posts session_start and batches events after 10 records', () async {
    final sink = CollectorHttpSink(config: configForServer());
    final session = createSession();
    sink.startSession(session);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sessionPosts, hasLength(1));
    expect(sessionPosts.first['eventType'], 'session_start');

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
    expect(batchPosts.first.first['eventType'], 'tap');
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
    expect(batchPosts.first.single['sessionId'], 'sess_server');
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
    expect(batchPosts.first.first['eventType'], 'tap');

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
    expect(batchPosts.last.map((event) => event['id']), [
      'event-10',
      'event-11',
    ]);
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

  test(
    'setTraits posts traits_updated, caches traitsId, stamps next events',
    () async {
      sessionResponseTraitsId = 'trt_abc';
      final sink = CollectorHttpSink(config: configForServer());
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
      final sink = CollectorHttpSink(config: configForServer());
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

  test('session lifecycle without traits bag sends cached traitsId', () async {
    final sink = CollectorHttpSink(
      config: configForServer(),
      initialTraitsId: 'trt_cached',
    );
    sink.startSession(createSession());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sessionPosts.first['eventType'], 'session_start');
    expect(sessionPosts.first['traitsId'], 'trt_cached');
    expect(sessionPosts.first.containsKey('traits'), isFalse);

    await sink.endSession();
    final endPost = sessionPosts.last;
    expect(endPost['eventType'], 'session_end');
    expect(endPost['traitsId'], 'trt_cached');
    expect(endPost.containsKey('traits'), isFalse);
    sink.dispose();
  });

  test('setUserId posts user_changed with cached traits', () async {
    sessionResponseTraitsId = 'trt_user';
    final sink = CollectorHttpSink(
      config: configForServer(),
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
    final sink = CollectorHttpSink(
      config: configForServer(),
      initialUserId: 'user_a',
    );
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
    final sink = CollectorHttpSink(config: configForServer());
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
      final sink = CollectorHttpSink(config: configForServer());
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

  test('endSession flushes debounced identity before session_end', () async {
    sessionResponseTraitsId = 'trt_end';
    final sink = CollectorHttpSink(config: configForServer());
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
    sink.dispose();
  });
}
