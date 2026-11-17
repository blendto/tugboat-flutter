import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_mapper.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// Real taps, produced through the widget pipeline, mapped for the HTTP
// collector. The in-memory envelope (`event.data`) is not what is uploaded:
// the mapper copies an explicit allow-list of keys.

const _production = TugboatReplayConfig(
  enabled: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

const _explorationOnlyKeys = ['fingerprintSource', 'routeKey', 'surface'];

/// Top-level keys of the interaction envelope that are intentionally NOT on the
/// collector record. Adding a field to the tap envelope fails the guard test
/// until it is either carried by `mapTugboatEventToCollectorEvent` or listed
/// here with the reason it stays on the device.
const _intentionallyNotUploaded = <String, String>{};

final _collectorConfig = TugboatCollectorConfig(
  baseUrl: 'https://collector.example.test',
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

List<TugboatEvent> _taps() => [
  for (final event
      in TugboatReplay.controller?.session?.events ?? const <TugboatEvent>[])
    if (event.type == 'interaction' && event.data['gesture'] == 'tap') event,
];

Future<TugboatEvent> _realTap(
  WidgetTester tester,
  TugboatReplayConfig config,
) async {
  await tester.pumpWidget(
    MaterialApp(
      initialRoute: '/home',
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: config, child: child!),
      routes: {
        '/home': (context) => Scaffold(
          body: Center(
            child: FilledButton(onPressed: () {}, child: const Text('Go')),
          ),
        ),
      },
    ),
  );
  await waitForTugboatCaptureWork(tester);
  await tester.tap(find.text('Go'));
  await tester.pump();
  for (var attempt = 0; attempt < 20 && _taps().isEmpty; attempt++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  await waitForTugboatCaptureWork(tester);
  expect(_taps(), hasLength(1));
  return _taps().single;
}

Map<String, Object?> _map(TugboatEvent event) {
  return mapTugboatEventToCollectorEvent(
    event: event,
    sessionStartedAt: DateTime.utc(2026, 6, 19),
    collectorConfig: _collectorConfig,
  );
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('an exploration tap reaches the collector with its evidence', (
    tester,
  ) async {
    final event = await _realTap(tester, _exploration);
    final mapped = _map(event);

    for (final key in [..._explorationOnlyKeys, 'fingerprintConfidence']) {
      expect(event.data[key], isNotNull, reason: '$key missing from envelope');
      expect(mapped[key], event.data[key], reason: '$key not uploaded');
    }
    expect(mapped['fingerprintSource'], 'pointerDown');
    expect(mapped['routeKey'], '/home');
    expect(mapped['surface'], {'kind': 'page'});
  });

  testWidgets('a production tap reaches the collector without them', (
    tester,
  ) async {
    final event = await _realTap(tester, _production);
    final mapped = _map(event);

    expect(mapped['targetFingerprint'], isNotNull);
    for (final key in _explorationOnlyKeys) {
      expect(mapped.containsKey(key), isFalse, reason: key);
    }
  });

  // The guard: every key of the tap envelope is uploaded or deliberately not.
  for (final (name, config) in [
    ('exploration', _exploration),
    ('production', _production),
  ]) {
    testWidgets('every $name tap envelope key is uploaded or listed', (
      tester,
    ) async {
      final event = await _realTap(tester, config);
      final mapped = _map(event);

      final dropped = <String>[
        for (final key in event.data.keys)
          if (!mapped.containsKey(key)) key,
      ];
      final unexplained = dropped
          .where((key) => !_intentionallyNotUploaded.containsKey(key))
          .toList();
      expect(
        unexplained,
        isEmpty,
        reason:
            'Tap envelope key(s) $unexplained are not on the collector '
            'record. Carry them in mapTugboatEventToCollectorEvent or add '
            'them to _intentionallyNotUploaded with a reason.',
      );
      for (final key in event.data.keys) {
        if (mapped.containsKey(key)) {
          expect(mapped[key], event.data[key], reason: '$key altered');
        }
      }
    });
  }
}
