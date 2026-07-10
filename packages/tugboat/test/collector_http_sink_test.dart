import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_http_sink.dart';
import 'package:tugboat/src/models.dart';

void main() {
  late HttpServer server;
  late Uri baseUri;
  final sessionPosts = <Map<String, dynamic>>[];
  final batchPosts = <List<Map<String, dynamic>>>[];
  final framePosts = <Map<String, dynamic>>[];
  var eventStatus = 202;
  var frameStatus = 202;
  var sessionStatus = 202;

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
    eventStatus = 202;
    frameStatus = 202;
    sessionStatus = 202;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUri = Uri.parse('http://127.0.0.1:${server.port}');

    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/v1/sessions') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        sessionPosts.add(Map<String, dynamic>.from(body));
        request.response
          ..statusCode = sessionStatus
          ..write(jsonEncode({'accepted': true, 'sessionId': 'sess_server'}));
      } else if (path == '/v1/events/batch') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final events = (body['events'] as List)
            .map((event) => Map<String, dynamic>.from(event as Map))
            .toList();
        batchPosts.add(events);
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
            r'filename="(\d+)\.png"',
          ).allMatches(encodedBody).map((match) => match.group(1)).toList(),
        });
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

  TugboatSession createSession() {
    return TugboatSession(
      id: 'session-local',
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
}
