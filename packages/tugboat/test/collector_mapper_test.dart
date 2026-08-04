import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_mapper.dart';
import 'package:tugboat/src/models.dart';

void main() {
  final collectorConfig = TugboatCollectorConfig(
    baseUrl: 'http://localhost:3000',
    apiKey: 'pmk_test',
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
      osVersion: '18',
    ),
    ipInfo: const TugboatCollectorIpInfo(ip: '127.0.0.1'),
    locale: const TugboatCollectorLocaleInfo(
      language: 'en',
      country: 'US',
      timezone: 'America/New_York',
    ),
    userId: 'user_1',
  );

  test('maps tugboat events into collector event schema', () {
    final sessionStartedAt = DateTime.utc(2026, 6, 19);
    final event = TugboatEvent(
      id: 'event-5',
      atMs: 28906,
      type: 'tap',
      beforeFrame: 'frame-3',
      stateAnchor: const TugboatStateAnchor(
        signature: '23f17a629520d522',
        signatureConfidence: 'medium',
        signatureParts: {'routeKey': '/intro'},
      ),
      targetAnchor: const TugboatTargetAnchor(
        widgetType: 'GestureDetector',
        role: 'button',
        fingerprint: '9eadb7c56ae836bc',
        fingerprintConfidence: 'low',
        canonicalPath: 'IntroScreen#0/PillButton#0',
        relativePosition: 'bottom',
      ),
      data: const {'x': 100, 'y': 200},
      actionId: 'A-1',
      explorationRunId: 'run-1',
    );

    final mapped = mapTugboatEventToCollectorEvent(
      event: event,
      sessionId: 'sess_123',
      sessionStartedAt: sessionStartedAt,
      userId: 'user_1',
      collectorConfig: collectorConfig,
    );

    expect(mapped['id'], 'event-5');
    expect(mapped['atMs'], 28906);
    expect(mapped['triggeredAt'], '2026-06-19T00:00:28.906Z');
    expect(mapped['sessionId'], 'sess_123');
    expect(mapped['userId'], 'user_1');
    expect(mapped['eventType'], 'tap');
    expect(mapped['stream'], tugboatEventStreamSemantic);
    // Compat path: semantic tap without canonical dual-write remains eligible.
    expect(mapped['enrichmentCandidate'], isTrue);
    expect(mapped['beforeFrame'], 'frame-3');
    expect((mapped['stateAnchor'] as Map)['signature'], '23f17a629520d522');
    expect((mapped['targetAnchor'] as Map)['fingerprint'], '9eadb7c56ae836bc');
    expect(mapped['actionId'], 'A-1');
    expect(mapped['explorationRunId'], 'run-1');
    expect((mapped['payload'] as Map)['x'], 100);
    expect((mapped['payload'] as Map)['actionId'], 'A-1');
    expect((mapped['payload'] as Map)['explorationRunId'], 'run-1');
    expect(mapped['build'], {
      'appId': 'com.example.app',
      'platform': 'ios',
      'versionName': '1.0.0',
      'buildNumber': '1',
      'fingerprintSchemaVersion': tugboatFingerprintSchemaVersion,
    });
  });

  test('marks legacy projection and evidence as non-enrichment candidates', () {
    final sessionStartedAt = DateTime.utc(2026, 6, 19);
    final legacy = mapTugboatEventToCollectorEvent(
      event: const TugboatEvent(
        id: 'event-legacy',
        atMs: 1,
        type: 'tap_settled',
        stream: TugboatEventStream.legacyProjection,
      ),
      sessionStartedAt: sessionStartedAt,
      collectorConfig: collectorConfig,
    );
    final evidence = mapTugboatEventToCollectorEvent(
      event: const TugboatEvent(
        id: 'event-route',
        atMs: 2,
        type: 'route_change',
        stream: TugboatEventStream.evidence,
      ),
      sessionStartedAt: sessionStartedAt,
      collectorConfig: collectorConfig,
    );
    final interaction = mapTugboatEventToCollectorEvent(
      event: const TugboatEvent(
        id: 'event-interaction',
        atMs: 3,
        type: 'interaction',
        stream: TugboatEventStream.semantic,
      ),
      sessionStartedAt: sessionStartedAt,
      collectorConfig: collectorConfig,
    );

    expect(legacy['enrichmentCandidate'], isFalse);
    expect(evidence['enrichmentCandidate'], isFalse);
    expect(interaction['enrichmentCandidate'], isTrue);
  });

  test('omits sessionId when not provided so the sink can stamp at send', () {
    final mapped = mapTugboatEventToCollectorEvent(
      event: TugboatEvent(id: 'event-1', atMs: 0, type: 'tap'),
      sessionStartedAt: DateTime.utc(2026, 6, 19),
      collectorConfig: collectorConfig,
    );
    expect(mapped.containsKey('sessionId'), isFalse);
    expect(mapped['build'], isNotNull);
  });

  test('maps session lifecycle payloads for collector sessions endpoint', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.sessionStart.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
    );

    expect(mapped['sessionId'], 'sess_123');
    expect(mapped['eventType'], 'session_start');
    expect(mapped['userId'], 'user_1');
    expect((mapped['appInfo'] as Map)['name'], 'Example App');
    expect((mapped['appInfo'] as Map)['appId'], 'com.example.app');
    expect((mapped['appInfo'] as Map)['packageName'], 'com.example.app');
    expect((mapped['device'] as Map)['platform'], 'ios');
    expect((mapped['ipInfo'] as Map)['ip'], '127.0.0.1');
    expect((mapped['locale'] as Map)['language'], 'en');
    expect(mapped['platform'], 'ios');
    expect(mapped['fingerprintSchemaVersion'], tugboatFingerprintSchemaVersion);
    expect(mapped.containsKey('traits'), isFalse);
    expect(mapped.containsKey('traitsId'), isFalse);
  });

  test('session map prefers full traits bag over traitsId', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.traitsUpdated.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      traits: {'plan': 'pro'},
      traitsId: 'trt_ignored',
    );

    expect(mapped['eventType'], 'traits_updated');
    expect(mapped['traits'], {'plan': 'pro'});
    expect(mapped.containsKey('traitsId'), isFalse);
  });

  test('session map sends traitsId when no traits bag is provided', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.sessionEnd.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      traitsId: 'trt_cached',
    );

    expect(mapped['traitsId'], 'trt_cached');
    expect(mapped.containsKey('traits'), isFalse);
  });

  test('event map includes optional traitsId', () {
    final mapped = mapTugboatEventToCollectorEvent(
      event: TugboatEvent(id: 'event-1', atMs: 0, type: 'tap'),
      sessionStartedAt: DateTime.utc(2026, 6, 19),
      collectorConfig: collectorConfig,
      traitsId: 'trt_evt',
    );

    expect(mapped['traitsId'], 'trt_evt');
  });

  test('session event type wire values match collector contract', () {
    expect(
      TugboatCollectorSessionEventType.sessionStart.wireValue,
      'session_start',
    );
    expect(
      TugboatCollectorSessionEventType.sessionEnd.wireValue,
      'session_end',
    );
    expect(
      TugboatCollectorSessionEventType.traitsUpdated.wireValue,
      'traits_updated',
    );
    expect(
      TugboatCollectorSessionEventType.userChanged.wireValue,
      'user_changed',
    );
  });

  test('keeps deprecated packageName legacy constructor compatibility', () {
    // ignore: deprecated_member_use_from_same_package
    const appInfo = TugboatCollectorAppInfo.legacyPackageName(
      name: 'Example App',
      version: '1.0.0',
      buildNumber: '1',
      installationId: 'inst_1',
      packageName: 'com.example.legacy',
    );

    expect(appInfo.appId, 'com.example.legacy');
    expect(appInfo.toJson()['appId'], 'com.example.legacy');
    expect(appInfo.toJson()['packageName'], 'com.example.legacy');
  });

  test('copies collector config with replay userId override', () {
    final copied = collectorConfig.withUserId('user_from_replay');

    expect(copied.userId, 'user_from_replay');
    expect(copied.baseUrl, collectorConfig.baseUrl);
    expect(copied.apiKey, collectorConfig.apiKey);
    expect(copied.appInfo, collectorConfig.appInfo);
    expect(copied.deviceInfo, collectorConfig.deviceInfo);
  });

  test('copying collector config preserves existing userId by default', () {
    expect(collectorConfig.withUserId(null).userId, 'user_1');
  });

  test('extracts frame numbers from tugboat frame ids', () {
    expect(frameNumberFromId('frame-0'), 0);
    expect(frameNumberFromId('frame-12'), 12);
    expect(frameNumberFromId('frame'), isNull);
  });
}
