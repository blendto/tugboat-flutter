import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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

  test('maps interaction events to facts-only schema v2', () {
    final sessionStartedAt = DateTime.utc(2026, 6, 19);
    final event = TugboatEvent(
      id: 'evt_interaction_1',
      atMs: 55957,
      type: 'interaction',
      stream: TugboatEventStream.semantic,
      beforeFrame: 'frame-34',
      afterFrame: 'frame-35',
      locale: const TugboatLocaleInfo(
        language: 'es',
        country: 'ES',
        tag: 'es-ES',
      ),
      data: {
        'interactionSchema': tugboatInteractionSchemaVersion,
        'route': '/home',
        'targetFingerprint': 'bef605389f2f5207',
        'gesture': 'tap',
        'payload': {
          'position': {'xNorm': 0.299, 'yNorm': 0.637},
        },
      },
    );

    final mapped = mapTugboatEventToCollectorEvent(
      event: event,
      sessionId: 'session-abc',
      sessionStartedAt: sessionStartedAt,
      userId: 'user_1',
      collectorConfig: collectorConfig,
    );

    expect(mapped['id'], 'evt_interaction_1');
    expect(mapped['eventType'], 'interaction');
    expect(mapped['interactionSchema'], 2);
    expect(mapped['route'], '/home');
    expect(mapped['targetFingerprint'], 'bef605389f2f5207');
    expect(mapped['gesture'], 'tap');
    expect(mapped['payload'], {
      'position': {'xNorm': 0.299, 'yNorm': 0.637},
    });
    expect(mapped.containsKey('position'), isFalse);
    expect(mapped['beforeFrame'], 'frame-34');
    expect(mapped['afterFrame'], 'frame-35');
    expect(mapped['locale'], {
      'language': 'es',
      'country': 'ES',
      'tag': 'es-ES',
    });
    expect(mapped.containsKey('result'), isFalse);
    expect(mapped.containsKey('targetAnchor'), isFalse);
    expect(mapped.containsKey('stateAnchor'), isFalse);
    final encoded = utf8.encode(jsonEncode(mapped));
    expect(encoded.length, lessThan(750));
  });

  test('maps cancelled interactions without payload', () {
    final mapped = mapTugboatEventToCollectorEvent(
      event: TugboatEvent(
        id: 'evt_cancelled_1',
        atMs: 1000,
        type: 'interaction',
        stream: TugboatEventStream.semantic,
        data: const {
          'interactionSchema': tugboatInteractionSchemaVersion,
          'gesture': 'cancelled',
        },
      ),
      sessionStartedAt: DateTime.utc(2026, 6, 19),
      collectorConfig: collectorConfig,
    );

    expect(mapped['gesture'], 'cancelled');
    expect(mapped.containsKey('payload'), isFalse);
  });

  test('maps scroll interactions with nested payload', () {
    final mapped = mapTugboatEventToCollectorEvent(
      event: TugboatEvent(
        id: 'evt_scroll_interaction_1',
        atMs: 15000,
        type: 'interaction',
        stream: TugboatEventStream.semantic,
        beforeFrame: 'frame-10',
        afterFrame: 'frame-11',
        data: const {
          'interactionSchema': tugboatInteractionSchemaVersion,
          'gesture': 'scroll',
          'targetFingerprint': 'abc123def4567890',
          'payload': {
            'position': {'xNorm': 0.30, 'yNorm': 0.64},
            'startOffset': 0.0,
            'endOffset': 240.0,
            'overscrollCount': 2,
          },
        },
      ),
      sessionStartedAt: DateTime.utc(2026, 6, 19),
      collectorConfig: collectorConfig,
    );

    expect(mapped['gesture'], 'scroll');
    expect(mapped['targetFingerprint'], 'abc123def4567890');
    expect((mapped['payload'] as Map)['startOffset'], 0.0);
    expect((mapped['payload'] as Map)['endOffset'], 240.0);
    expect((mapped['payload'] as Map)['overscrollCount'], 2);
    expect(mapped.containsKey('scrollSchema'), isFalse);
  });

  test('maps pan and zoom interactions with nested payload', () {
    final pan = mapTugboatEventToCollectorEvent(
      event: TugboatEvent(
        id: 'evt_pan_1',
        atMs: 2000,
        type: 'interaction',
        stream: TugboatEventStream.semantic,
        data: const {
          'interactionSchema': tugboatInteractionSchemaVersion,
          'gesture': 'pan',
          'payload': {
            'position': {'xNorm': 0.4, 'yNorm': 0.4},
            'endPosition': {'xNorm': 0.4, 'yNorm': 0.6},
            'delta': {'xNorm': 0.0, 'yNorm': 0.2},
            'pointerCount': 2,
          },
        },
      ),
      sessionStartedAt: DateTime.utc(2026, 6, 19),
      collectorConfig: collectorConfig,
    );
    expect(pan['gesture'], 'pan');
    expect((pan['payload'] as Map)['pointerCount'], 2);

    for (final entry in {'zoom_in': 1.4, 'zoom_out': 0.7}.entries) {
      final zoom = mapTugboatEventToCollectorEvent(
        event: TugboatEvent(
          id: 'evt_${entry.key}',
          atMs: 3000,
          type: 'interaction',
          stream: TugboatEventStream.semantic,
          data: {
            'interactionSchema': tugboatInteractionSchemaVersion,
            'gesture': entry.key,
            'payload': {
              'position': {'xNorm': 0.5, 'yNorm': 0.5},
              'scale': entry.value,
              'pointerCount': 2,
            },
          },
        ),
        sessionStartedAt: DateTime.utc(2026, 6, 19),
        collectorConfig: collectorConfig,
      );
      expect(zoom['gesture'], entry.key);
      expect((zoom['payload'] as Map)['scale'], entry.value);
      expect((zoom['payload'] as Map)['pointerCount'], 2);
    }
  });

  test('maps route_change events to facts-only schema v2', () {
    final sessionStartedAt = DateTime.utc(2026, 6, 19);
    final event = TugboatEvent(
      id: 'evt_route_1',
      atMs: 12000,
      type: 'route_change',
      stream: TugboatEventStream.evidence,
      afterFrame: 'frame-8',
      data: const {
        'fromRoute': '/home',
        'route': '/settings',
        'navigation': 'route_push',
        'causeEventId': 'event-interaction-1',
        'navigatorId': 'nav-1',
        'captureOutcome': 'captured',
        'navigationOrigin': 'user_gesture',
      },
    );

    final mapped = mapTugboatEventToCollectorEvent(
      event: event,
      sessionId: 'session-abc',
      sessionStartedAt: sessionStartedAt,
      userId: 'user_1',
      collectorConfig: collectorConfig,
    );

    expect(mapped['eventType'], 'route_change');
    expect(mapped['routeChangeSchema'], tugboatRouteChangeSchemaVersion);
    expect(mapped['fromRoute'], '/home');
    expect(mapped['route'], '/settings');
    expect(mapped['navigation'], 'route_push');
    expect(mapped['causeEventId'], 'event-interaction-1');
    expect(mapped['afterFrame'], 'frame-8');
    expect(mapped.containsKey('result'), isFalse);
    expect(mapped.containsKey('payload'), isFalse);
    expect(mapped.containsKey('targetAnchor'), isFalse);
    expect(mapped.containsKey('navigatorId'), isFalse);
    expect(mapped.containsKey('captureOutcome'), isFalse);
    expect(mapped.containsKey('navigationOrigin'), isFalse);
    final encoded = utf8.encode(jsonEncode(mapped));
    expect(encoded.length, lessThan(700));
  });

  test('maps overlay identity and presentation parent on route_change', () {
    final mapped = mapTugboatEventToCollectorEvent(
      event: TugboatEvent(
        id: 'evt_route_overlay',
        atMs: 12000,
        type: 'route_change',
        stream: TugboatEventStream.evidence,
        data: const {
          'fromRoute': '/subscriptionPaywall',
          'fromRouteName': '/subscriptionPaywall',
          'fromRouteType': 'PopupRoute<dynamic>',
          'fromRouteNamed': true,
          'route': 'ModalBottomSheetRoute<void>',
          'routeType': 'ModalBottomSheetRoute<void>',
          'routeNamed': false,
          'navigation': 'route_push',
          'overlayKind': 'sheet',
          'presentedOverRoute': '/subscriptionPaywall',
          'presentedOverRouteInstanceId': 'route-14',
          'presentedOverOverlayKind': 'popup',
          'hostPageRoute': '/home',
          'hostPageRouteInstanceId': 'route-2',
          'routeStack': [
            {
              'routeInstanceId': 'route-2',
              'route': '/home',
              'routeNamed': true,
              'overlayKind': 'page',
              'navigatorId': 'nav-0',
            },
          ],
          'causeEventId': 'event-88',
          'causedByInteractionId': 'event-88',
          'causeTargetFingerprint': 'a1b2c3d4e5f6a7b8',
          'causeGesture': 'tap',
          'navigatorId': 'nav-0',
          'routeStackTruncated': true,
        },
      ),
      sessionStartedAt: DateTime.utc(2026, 6, 19),
      collectorConfig: collectorConfig,
    );

    expect(mapped['routeNamed'], isFalse);
    expect(mapped['overlayKind'], 'sheet');
    expect(mapped['presentedOverRoute'], '/subscriptionPaywall');
    expect(mapped['hostPageRoute'], '/home');
    expect(mapped['causeTargetFingerprint'], 'a1b2c3d4e5f6a7b8');
    expect(mapped['causeGesture'], 'tap');
    expect(mapped['routeStackTruncated'], isTrue);
    expect(mapped.containsKey('navigatorId'), isFalse);
    expect(mapped['routeStack'], isA<List>());
  });

  test('generic branch omits empty targetAnchor and payload stream', () {
    final mapped = mapTugboatEventToCollectorEvent(
      event: TugboatEvent(
        id: 'event-app-bg',
        atMs: 100,
        type: 'app_backgrounded',
        stream: TugboatEventStream.evidence,
        data: const {'reason': 'lifecycle'},
      ),
      sessionStartedAt: DateTime.utc(2026, 6, 19),
      collectorConfig: collectorConfig,
    );

    expect(mapped.containsKey('targetAnchor'), isFalse);
    expect((mapped['payload'] as Map).containsKey('stream'), isFalse);
    expect((mapped['payload'] as Map)['reason'], 'lifecycle');
  });

  test('marks evidence as a non-enrichment candidate', () {
    final sessionStartedAt = DateTime.utc(2026, 6, 19);
    final evidence = mapTugboatEventToCollectorEvent(
      event: const TugboatEvent(
        id: 'event-route',
        atMs: 1,
        type: 'route_change',
        stream: TugboatEventStream.evidence,
      ),
      sessionStartedAt: sessionStartedAt,
      collectorConfig: collectorConfig,
    );
    final interaction = mapTugboatEventToCollectorEvent(
      event: const TugboatEvent(
        id: 'event-interaction',
        atMs: 2,
        type: 'interaction',
        stream: TugboatEventStream.semantic,
      ),
      sessionStartedAt: sessionStartedAt,
      collectorConfig: collectorConfig,
    );

    expect(evidence['enrichmentCandidate'], isFalse);
    expect(interaction['enrichmentCandidate'], isTrue);
  });

  test('omits sessionId when not provided so the sink can stamp at send', () {
    final mapped = mapTugboatEventToCollectorEvent(
      event: TugboatEvent(id: 'event-1', atMs: 0, type: 'capture_diagnostic'),
      sessionStartedAt: DateTime.utc(2026, 6, 19),
      collectorConfig: collectorConfig,
    );
    expect(mapped.containsKey('sessionId'), isFalse);
    expect(mapped['build'], isNotNull);
  });

  test('maps only session context on session_start', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.sessionStart.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      activeLocale: const TugboatLocaleInfo(
        language: 'es',
        country: 'ES',
        tag: 'es-ES',
      ),
    );

    expect(mapped['sessionId'], 'sess_123');
    expect(mapped['eventType'], 'session_start');
    expect(mapped['userId'], 'user_1');
    expect((mapped['appInfo'] as Map).containsKey('name'), isFalse);
    expect((mapped['appInfo'] as Map).containsKey('installationId'), isFalse);
    expect((mapped['appInfo'] as Map)['appId'], 'com.example.app');
    expect((mapped['appInfo'] as Map)['packageName'], 'com.example.app');
    expect((mapped['device'] as Map)['platform'], 'ios');
    expect((mapped['ipInfo'] as Map)['ip'], '127.0.0.1');
    expect(mapped['locale'], {
      'timezone': 'America/New_York',
      'language': 'es',
      'country': 'ES',
      'tag': 'es-ES',
    });
    expect(mapped.containsKey('platform'), isFalse);
    expect(mapped.containsKey('fingerprintSchemaVersion'), isFalse);
    expect(mapped.containsKey('traits'), isFalse);
    expect(mapped.containsKey('traitsId'), isFalse);
  });

  test('session map prefers full traits bag over traitsId', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.traitsUpdated.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      userId: 'user_1',
      traits: {'plan': 'pro'},
      traitsId: 'trt_ignored',
    );

    expect(mapped['eventType'], 'traits_updated');
    expect(mapped['traits'], {'plan': 'pro'});
    expect(mapped['userId'], 'user_1');
    expect(mapped.containsKey('traitsId'), isFalse);
    expect(mapped.containsKey('appInfo'), isFalse);
    expect(mapped.containsKey('device'), isFalse);
  });

  test('traits_updated stamps the current runtime userId', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.traitsUpdated.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      userId: 'user_runtime',
      traits: {'plan': 'pro'},
    );

    expect(mapped, {
      'sessionId': 'sess_123',
      'eventType': 'traits_updated',
      'triggeredAt': '2026-06-19T00:00:00.000Z',
      'userId': 'user_runtime',
      'traits': {'plan': 'pro'},
    });
  });

  test('traits_updated sends null userId when identity is unset', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.traitsUpdated.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      userId: null,
      traits: {'plan': 'free'},
    );

    expect(mapped['userId'], isNull);
    expect(mapped.containsKey('userId'), isTrue);
  });

  test('session_end stamps userId and traitsId when no bag is set', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.sessionEnd.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      userId: 'user_1',
      traitsId: 'trt_cached',
    );

    expect(mapped, {
      'sessionId': 'sess_123',
      'eventType': 'session_end',
      'triggeredAt': '2026-06-19T00:00:00.000Z',
      'userId': 'user_1',
      'traitsId': 'trt_cached',
    });
  });

  test('session_end prefers the full traits bag over traitsId', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.sessionEnd.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      userId: 'user_1',
      traits: {'plan': 'pro'},
      traitsId: 'trt_ignored',
    );

    expect(mapped, {
      'sessionId': 'sess_123',
      'eventType': 'session_end',
      'triggeredAt': '2026-06-19T00:00:00.000Z',
      'userId': 'user_1',
      'traits': {'plan': 'pro'},
    });
  });

  test('session_identify sends only its user and traits changes', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.sessionIdentify.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      userId: 'user_2',
      traits: {'plan': 'pro'},
    );

    expect(mapped, {
      'sessionId': 'sess_123',
      'eventType': 'session_identify',
      'triggeredAt': '2026-06-19T00:00:00.000Z',
      'userId': 'user_2',
      'traits': {'plan': 'pro'},
    });
  });

  test('user_changed stamps userId and the current traits bag', () {
    final mapped = mapTugboatSessionLifecycleToCollectorSession(
      eventType: TugboatCollectorSessionEventType.userChanged.wireValue,
      sessionId: 'sess_123',
      triggeredAt: DateTime.utc(2026, 6, 19),
      config: collectorConfig,
      userId: null,
      traits: {'plan': 'pro'},
    );

    expect(mapped, {
      'sessionId': 'sess_123',
      'eventType': 'user_changed',
      'triggeredAt': '2026-06-19T00:00:00.000Z',
      'userId': null,
      'traits': {'plan': 'pro'},
    });
  });

  test('event map includes optional traitsId', () {
    final mapped = mapTugboatEventToCollectorEvent(
      event: TugboatEvent(id: 'event-1', atMs: 0, type: 'capture_diagnostic'),
      sessionStartedAt: DateTime.utc(2026, 6, 19),
      collectorConfig: collectorConfig,
      traitsId: 'trt_evt',
    );

    expect(mapped['traitsId'], 'trt_evt');
  });

  test('session event type wire values match collector contract', () {
    expect(
      TugboatCollectorSessionEventType.sessionIdentify.wireValue,
      'session_identify',
    );
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
