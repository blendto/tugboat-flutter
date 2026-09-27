import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_mapper.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

const _baseConfig = TugboatReplayConfig(
  enabled: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

const _focusConfig = TugboatReplayConfig(
  enabled: true,
  captureFocusChanges: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

const _systemConfig = TugboatReplayConfig(
  enabled: true,
  captureSystemInput: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

void _useSeededCaptures() {
  TugboatReplay.debugConfigureControllerForTest = (controller) {
    controller.debugExecuteCapture =
        ({required trigger, required force}) async =>
            controller.debugSeedFrame(trigger: trigger);
  };
}

List<TugboatEvent> _events(String type) => TugboatReplay
    .controller!
    .session!
    .events
    .where((event) => event.type == type)
    .toList(growable: false);

Future<List<TugboatEvent>> _waitForEvents(
  WidgetTester tester,
  String type,
  int count,
) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (_events(type).length >= count) break;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await waitForTugboatCaptureWork(tester);
  return _events(type);
}

/// Pumps enough frames and async turns for any late event to have landed.
Future<void> _settle(WidgetTester tester) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await waitForTugboatCaptureWork(tester);
}

void _expectFrameExists(TugboatEvent event) {
  final frameIds = TugboatReplay.controller!.session!.frames.map((f) => f.id);
  expect(event.afterFrame, isNotNull);
  expect(frameIds, contains(event.afterFrame));
}

Widget _fieldsApp(
  TugboatReplayConfig config, {
  required FocusNode first,
  required FocusNode second,
}) => MaterialApp(
  navigatorObservers: [TugboatReplay.navigatorObserver],
  builder: (context, child) =>
      TugboatReplay.wrapApp(config: config, child: child!),
  home: Scaffold(
    body: Column(
      children: [
        TextField(focusNode: first, textInputAction: TextInputAction.next),
        TextField(focusNode: second),
        const ElevatedButton(onPressed: null, child: Text('Not a field')),
      ],
    ),
  ),
);

Widget _routesApp(TugboatReplayConfig config) => MaterialApp(
  navigatorObservers: [TugboatReplay.navigatorObserver],
  builder: (context, child) =>
      TugboatReplay.wrapApp(config: config, child: child!),
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Details')),
          ),
        ),
        child: const Text('Open'),
      ),
    ),
  ),
);

void main() {
  group('focus changes', () {
    testWidgets(
      'programmatic focus, keyboard next, and unfocus each capture a frame',
      (tester) async {
        _useSeededCaptures();
        addTearDown(TugboatReplay.resetForTest);
        final first = FocusNode();
        final second = FocusNode();
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        await tester.pumpWidget(
          _fieldsApp(_focusConfig, first: first, second: second),
        );
        await waitForTugboatCaptureWork(tester);

        // No pointer is involved in any of these transitions.
        first.requestFocus();
        await tester.pump();
        var events = await _waitForEvents(tester, 'focus_changed', 1);
        expect(events.single.data, {
          'focus': 'text_input',
          'previousFocus': isNot('text_input'),
        });

        await tester.testTextInput.receiveAction(TextInputAction.next);
        await tester.pump();
        events = await _waitForEvents(tester, 'focus_changed', 2);
        expect(second.hasPrimaryFocus, isTrue);
        expect(events[1].data, {
          'focus': 'text_input',
          'previousFocus': 'text_input',
        });

        second.unfocus();
        await tester.pump();
        events = await _waitForEvents(tester, 'focus_changed', 3);
        expect(events[2].data['focus'], isNot('text_input'));
        expect(events[2].data['previousFocus'], 'text_input');

        for (final event in events) {
          expect(event.stream, TugboatEventStream.evidence);
          _expectFrameExists(event);
        }
        final json = TugboatReplay.controller!.session!.toJson().toString();
        expect(json, isNot(contains('Not a field')));
      },
    );

    testWidgets('route focus churn without a text field is not recorded', (
      tester,
    ) async {
      _useSeededCaptures();
      addTearDown(TugboatReplay.resetForTest);
      await tester.pumpWidget(_routesApp(_focusConfig));
      await waitForTugboatCaptureWork(tester);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await _settle(tester);

      expect(_events('route_change'), isNotEmpty);
      expect(_events('focus_changed'), isEmpty);
    });

    testWidgets('focus changes are not recorded unless enabled', (
      tester,
    ) async {
      _useSeededCaptures();
      addTearDown(TugboatReplay.resetForTest);
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        _fieldsApp(_baseConfig, first: first, second: second),
      );
      await waitForTugboatCaptureWork(tester);

      first.requestFocus();
      await tester.pump();
      await _settle(tester);

      expect(first.hasPrimaryFocus, isTrue);
      expect(_events('focus_changed'), isEmpty);
    });
  });

  group('system input', () {
    testWidgets('volume keys are recorded once per press without consuming', (
      tester,
    ) async {
      _useSeededCaptures();
      addTearDown(TugboatReplay.resetForTest);
      final seen = <LogicalKeyboardKey>[];
      bool hostHandler(KeyEvent event) {
        if (event is KeyDownEvent) seen.add(event.logicalKey);
        return false;
      }

      HardwareKeyboard.instance.addHandler(hostHandler);
      addTearDown(() => HardwareKeyboard.instance.removeHandler(hostHandler));
      await tester.pumpWidget(_routesApp(_systemConfig));
      await waitForTugboatCaptureWork(tester);

      await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
      await simulateKeyRepeatEvent(LogicalKeyboardKey.audioVolumeUp);
      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
      await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
      // Ordinary keys are never recorded.
      await simulateKeyDownEvent(LogicalKeyboardKey.keyA);
      await simulateKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      final events = await _waitForEvents(tester, 'system_input', 2);
      await _settle(tester);
      expect(_events('system_input').map((event) => event.data['input']), [
        'volume_up',
        'volume_down',
      ]);
      for (final event in events) {
        expect(event.stream, TugboatEventStream.evidence);
        _expectFrameExists(event);
      }
      expect(seen, [
        LogicalKeyboardKey.audioVolumeUp,
        LogicalKeyboardKey.audioVolumeDown,
        LogicalKeyboardKey.keyA,
      ]);
    });

    testWidgets('system back is recorded and still pops the route', (
      tester,
    ) async {
      _useSeededCaptures();
      addTearDown(TugboatReplay.resetForTest);
      await tester.pumpWidget(_routesApp(_systemConfig));
      await waitForTugboatCaptureWork(tester);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await waitForTugboatCaptureWork(tester);
      expect(find.text('Details'), findsOneWidget);

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue, reason: 'the app, not Tugboat, handles back');
      expect(find.text('Details'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      final events = await _waitForEvents(tester, 'system_input', 1);
      expect(events.single.data, {'input': 'back'});
      _expectFrameExists(events.single);
      final pop = _events(
        'route_change',
      ).lastWhere((event) => event.data['navigation'] == 'route_pop');
      expect(pop.afterFrame, isNotNull);
    });

    testWidgets('system input is not recorded unless enabled', (tester) async {
      _useSeededCaptures();
      addTearDown(TugboatReplay.resetForTest);
      await tester.pumpWidget(_routesApp(_baseConfig));
      await waitForTugboatCaptureWork(tester);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeUp);
      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeUp);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _settle(tester);

      expect(find.text('Details'), findsNothing);
      expect(_events('system_input'), isEmpty);
    });

    testWidgets('a pending observation is published before session end', (
      tester,
    ) async {
      _useSeededCaptures();
      addTearDown(TugboatReplay.resetForTest);
      await tester.pumpWidget(
        _routesApp(_systemConfig.copyWith(settleDelay: Duration(hours: 1))),
      );
      await waitForTugboatCaptureWork(tester);

      await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeMute);
      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeMute);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      final controller = TugboatReplay.controller!;
      final session = controller.session!;
      expect(_events('system_input'), isEmpty, reason: 'still observing');

      await controller.endSession();

      final types = session.events.map((event) => event.type).toList();
      final input = session.events.singleWhere(
        (event) => event.type == 'system_input',
      );
      expect(input.data, {'input': 'volume_mute'});
      expect(input.afterFrame, isNull);
      expect(
        types.indexOf('system_input'),
        lessThan(types.indexOf('session_end')),
      );
      await _settle(tester);
      expect(
        session.events.where((event) => event.type == 'system_input'),
        hasLength(1),
      );
    });

    test('only allowlisted keys map to system inputs', () {
      expect(
        TugboatSystemInput.fromLogicalKey(LogicalKeyboardKey.audioVolumeUp),
        TugboatSystemInput.volumeUp,
      );
      expect(
        TugboatSystemInput.fromLogicalKey(LogicalKeyboardKey.goBack),
        null,
      );
      expect(TugboatSystemInput.fromLogicalKey(LogicalKeyboardKey.keyA), null);
      expect(TugboatSystemInput.fromLogicalKey(LogicalKeyboardKey.enter), null);
      expect(
        TugboatSystemInput.fromLogicalKey(LogicalKeyboardKey.arrowDown),
        null,
      );
    });
  });

  test('collector payload keeps the closed input vocabulary', () {
    final mapped = mapTugboatEventToCollectorEvent(
      event: const TugboatEvent(
        id: 'event-1',
        atMs: 10,
        type: 'system_input',
        stream: TugboatEventStream.evidence,
        afterFrame: 'frame-2',
        data: {'input': 'back'},
      ),
      sessionStartedAt: DateTime.utc(2026),
      collectorConfig: const TugboatCollectorConfig(
        baseUrl: 'https://collector.example.test',
        apiKey: 'pmk_test',
        appInfo: TugboatCollectorAppInfo(
          name: 'Example App',
          version: '1.0.0',
          buildNumber: '1',
          installationId: 'inst_1',
          appId: 'com.example.app',
        ),
        deviceInfo: TugboatCollectorDeviceInfo(
          id: 'device_client',
          platform: 'android',
          screenSize: TugboatCollectorScreenSize(width: 390, height: 844),
          screenDensity: 3,
          screenDpi: 460,
          screenPixelDensity: 3,
          osVersion: '15',
        ),
        ipInfo: TugboatCollectorIpInfo(ip: '127.0.0.1'),
        locale: TugboatCollectorLocaleInfo(
          language: 'en',
          country: 'US',
          timezone: 'UTC',
        ),
      ),
    );
    expect(mapped['eventType'], 'system_input');
    expect(mapped['stream'], 'evidence');
    expect(mapped['afterFrame'], 'frame-2');
    expect(mapped['payload'], {'input': 'back'});
    expect(mapped['enrichmentCandidate'], isFalse);
  });
}
