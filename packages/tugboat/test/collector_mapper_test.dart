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
    );

    expect(mapped['id'], 'event-5');
    expect(mapped['atMs'], 28906);
    expect(mapped['triggeredAt'], '2026-06-19T00:00:28.906Z');
    expect(mapped['sessionId'], 'sess_123');
    expect(mapped['userId'], 'user_1');
    expect(mapped['eventType'], 'tap');
    expect(mapped['beforeFrame'], 'frame-3');
    expect(
      (mapped['stateAnchor'] as Map)['signature'],
      '23f17a629520d522',
    );
    expect(
      (mapped['targetAnchor'] as Map)['fingerprint'],
      '9eadb7c56ae836bc',
    );
    expect(mapped['actionId'], 'A-1');
    expect(mapped['explorationRunId'], 'run-1');
    expect((mapped['payload'] as Map)['x'], 100);
    expect((mapped['payload'] as Map)['actionId'], 'A-1');
    expect((mapped['payload'] as Map)['explorationRunId'], 'run-1');
  });

  test('maps session lifecycle payloads for collector sessions endpoint', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: 'session_start',
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
    );

    expect(mapped['sessionId'], 'sess_123');
    expect(mapped['eventType'], 'session_start');
    expect(mapped['userId'], 'user_1');
    expect((mapped['appInfo'] as Map)['name'], 'Example App');
    expect((mapped['device'] as Map)['platform'], 'ios');
    expect((mapped['ipInfo'] as Map)['ip'], '127.0.0.1');
    expect((mapped['locale'] as Map)['language'], 'en');
    expect(mapped['platform'], 'ios');
    expect(mapped['fingerprintSchemaVersion'], tugboatFingerprintSchemaVersion);
  });

  test('extracts frame numbers from tugboat frame ids', () {
    expect(frameNumberFromId('frame-0'), 0);
    expect(frameNumberFromId('frame-12'), 12);
  });
}
