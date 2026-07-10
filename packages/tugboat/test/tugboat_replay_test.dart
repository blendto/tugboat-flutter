import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tugboat/tugboat.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/perceptual_hash.dart' show computeDHashFromRgba;

import 'helpers/json_roundtrip.dart';

const _testConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  enableGlobalPointerCapture: false,
  scrollCaptureInterval: Duration(milliseconds: 50),
  captureScrollSamples: true,
  capturePixelRatio: 1.0,
);

Future<void> _waitForCaptures(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
}

bool _containsLabelTelemetry(Object? value) {
  const labelKeys = {
    'labels',
    'ancestorLabels',
    'descendantLabels',
    'accessibilityLabels',
    'iconLabels',
    'iconHashes',
  };
  if (value is Map) {
    return value.entries.any(
      (entry) =>
          labelKeys.contains(entry.key) || _containsLabelTelemetry(entry.value),
    );
  }
  if (value is Iterable) return value.any(_containsLabelTelemetry);
  return false;
}

void main() {
  testWidgets('detached lifecycle emits session_end once', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: const SizedBox.expand(),
      ),
    );
    await tester.pump();

    final session = TugboatReplay.controller!.session!;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();

    expect(
      session.events.where((event) => event.type == 'session_end'),
      hasLength(1),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('paused lifecycle does not emit session_end', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: const SizedBox.expand(),
      ),
    );
    await tester.pump();

    final session = TugboatReplay.controller!.session!;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      session.events.where((event) => event.type == 'session_end'),
      isEmpty,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('captures initial screenshot and tap interaction anchors', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: Column(
            children: [
              const Text('Visible label'),
              const TextField(),
              FilledButton(onPressed: () {}, child: const Text('Continue')),
            ],
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);

    final controller = TugboatReplay.controller!;
    final session = controller.session!;
    expect(session.events.first.type, 'session_start');
    expect(session.events.first.sessionId, session.id);
    expect(session.frames, isNotEmpty);
    expect(session.frameBytes, isNotEmpty);
    expect(session.averageFrameBytes, greaterThan(0));
    expect(session.frames.every((frame) => frame.captureMicros > 0), isTrue);
    expect(session.frames.every((frame) => frame.masked), isFalse);

    await tester.tap(find.text('Continue'));
    await _waitForCaptures(tester);

    final tapEvents = session.events.where((e) => e.type == 'tap').toList();
    expect(tapEvents, isNotEmpty);
    expect(tapEvents.first.targetAnchor, isNotNull);
    expect(tapEvents.first.targetAnchor!.widgetType, isNot('RepaintBoundary'));
    expect(tapEvents.first.targetAnchor!.role, 'button');
    expect(tapEvents.first.targetAnchor!.fingerprint, isNotNull);
    expect(tapEvents.first.targetAnchor!.fingerprintConfidence, isNotNull);
    expect(tapEvents.first.targetAnchor!.canonicalPath, isNotEmpty);
    expect(
      tapEvents.first.targetAnchor!.fingerprintParts,
      containsPair('schemaVersion', tugboatFingerprintSchemaVersion.toString()),
    );
    expect(
      tapEvents.first.targetAnchor!.fingerprintParts.containsKey('labels'),
      isFalse,
    );
    expect(_containsLabelTelemetry(session.toJson()), isFalse);
    expect(tapEvents.first.targetAnchor!.relativePosition, isNotNull);
    expect(tapEvents.first.beforeFrame, isNotNull);

    final settled = session.events
        .where((e) => e.type == 'tap_settled')
        .toList();
    expect(settled, isNotEmpty);
    expect(settled.first.relatedEventId, tapEvents.first.id);
    expect(settled.first.targetAnchor?.role, 'button');
    expect(
      settled.first.targetAnchor?.canonicalPath,
      tapEvents.first.targetAnchor?.canonicalPath,
    );
    expect(settled.first.afterFrame, isNotNull);
  });

  testWidgets('captures route changes with destination screenshot', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: '/next'),
                  builder: (_) => const Scaffold(body: Text('Next screen')),
                ),
              ),
              child: const Text('Next'),
            ),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await _waitForCaptures(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await _waitForCaptures(tester);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pump();

    final session = TugboatReplay.controller!.session!;
    final routeChanges = session.events
        .where((event) => event.type == 'route_change')
        .toList();
    expect(routeChanges, isNotEmpty);
    final routeChange = routeChanges.first;
    expect(routeChange.data['route'], isNotNull);
    expect(routeChange.data['navigation'], 'route_push');
    final routeChangeJson = routeChange.toJson();
    expect(routeChangeJson.containsKey('route'), isFalse);
    expect(routeChangeJson.containsKey('toRoute'), isFalse);
    expect(
      (routeChangeJson['stateAnchor'] as Map<String, Object?>).containsKey(
        'route',
      ),
      isFalse,
    );
    expect(session.frames, isNotEmpty);

    await tester.pump(const Duration(milliseconds: 400));
    await _waitForCaptures(tester);
  });

  testWidgets('uses one data payload for every navigation operation', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: const SizedBox(width: 390, height: 844),
      ),
    );
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: rootKey,
    );
    controller.start(const Size(390, 844), 'test');

    PageRoute<void> route(String name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      transitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const SizedBox.shrink(),
    );

    await tester.runAsync(() async {
      await controller.route('route_push', route('/a'));
      await controller.route('route_replace', route('/b'));
      await controller.route('route_pop', route('/a'));
      await controller.route('route_remove', route('/b'));
    });

    final changes = controller.session!.events
        .where((event) => event.type == 'route_change')
        .toList();
    expect(changes.map((event) => event.data['navigation']), [
      'route_push',
      'route_replace',
      'route_pop',
      'route_remove',
    ]);
    expect(changes[0].data, {'route': '/a', 'navigation': 'route_push'});
    expect(changes[1].data, {
      'fromRoute': '/a',
      'route': '/b',
      'navigation': 'route_replace',
    });
    expect(changes[2].data, {
      'fromRoute': '/b',
      'route': '/a',
      'navigation': 'route_pop',
    });
    expect(changes[3].data, {
      'fromRoute': '/a',
      'route': '/b',
      'navigation': 'route_remove',
    });
    for (final event in changes) {
      expect(event.toJson().containsKey('route'), isFalse);
      expect(event.toJson().containsKey('toRoute'), isFalse);
    }
    controller.dispose();
  });

  testWidgets('skips route_remove when visible route is unchanged', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: const SizedBox(width: 390, height: 844),
      ),
    );
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: rootKey,
    );
    controller.start(const Size(390, 844), 'test');

    PageRoute<void> route(String name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      transitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const SizedBox.shrink(),
    );

    await tester.runAsync(() async {
      await controller.route('route_push', route('/'));
      await controller.route('route_push', route('/intro'));
      await controller.route('route_remove', route('/intro'));
    });

    final changes = controller.session!.events
        .where((event) => event.type == 'route_change')
        .toList();
    expect(changes.map((event) => event.data['navigation']), [
      'route_push',
      'route_push',
    ]);
    expect(changes[0].data, {'route': '/', 'navigation': 'route_push'});
    expect(changes[1].data, {
      'fromRoute': '/',
      'route': '/intro',
      'navigation': 'route_push',
    });
    controller.dispose();
  });

  testWidgets('stale route callbacks do not clobber newer routes', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: const SizedBox(width: 390, height: 844),
      ),
    );
    final controller = TugboatReplayController(
      config: const TugboatReplayConfig(
        profile: TugboatCaptureProfile.exploration,
        settleDelay: Duration(milliseconds: 50),
        enableGlobalPointerCapture: false,
        capturePixelRatio: 1.0,
      ),
      boundaryKey: rootKey,
    );
    controller.start(const Size(390, 844), 'test');

    PageRoute<void> delayedRoute(String name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => const SizedBox.shrink(),
    );
    PageRoute<void> instantRoute(String name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      transitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const SizedBox.shrink(),
    );

    await tester.runAsync(() async {
      final homeFuture = controller.route('route_push', delayedRoute('/home'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await controller.route('route_push', instantRoute('/paywall'));
      await homeFuture;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });

    expect(controller.currentRoute, '/paywall');

    final changes = controller.session!.events
        .where((event) => event.type == 'route_change')
        .toList();
    expect(
      changes.where((event) => event.data['route'] == '/home'),
      isEmpty,
      reason: 'stale /home callback must not emit route_change',
    );
    expect(changes.last.data['route'], '/paywall');

    controller.dispose();
  });

  testWidgets('captures scroll checkpoints and samples', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: ListView(
            children: [
              for (var index = 0; index < 30; index++)
                SizedBox(height: 80, child: Text('Row $index')),
            ],
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final types = session.events.map((event) => event.type).toList();
    expect(types, containsAll(['scroll_start', 'scroll_end']));
    final scrollStart = session.events.firstWhere(
      (event) => event.type == 'scroll_start',
    );
    expect(scrollStart.stateAnchor?.actionableSummary['scrollable'], 1);
    expect(session.scrollSamples, isNotEmpty);
    expect(session.frames, isNotEmpty);
  });

  testWidgets('masks only TugboatSensitive subtrees in screenshots', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: const Scaffold(
          body: Column(
            children: [
              Text('Visible label'),
              TugboatSensitive(child: Text('Hidden label')),
            ],
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    expect(session.frames, isNotEmpty);
    expect(session.frames.any((frame) => frame.masked), isTrue);
  });

  test('mask defaults follow the capture profile', () {
    expect(
      const TugboatReplayConfig(
        profile: TugboatCaptureProfile.exploration,
      ).effectiveScreenshotMaskLevel,
      TugboatScreenshotMaskLevel.explicitOnly,
    );
    expect(
      const TugboatReplayConfig(
        profile: TugboatCaptureProfile.productionLean,
      ).effectiveScreenshotMaskLevel,
      TugboatScreenshotMaskLevel.allTextAndMedia,
    );
    expect(
      const TugboatReplayConfig(
        profile: TugboatCaptureProfile.productionLean,
        screenshotMaskLevel: TugboatScreenshotMaskLevel.sensitiveInputsOnly,
      ).effectiveScreenshotMaskLevel,
      TugboatScreenshotMaskLevel.sensitiveInputsOnly,
    );
  });

  testWidgets('productionLean automatically masks visible text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(
            profile: TugboatCaptureProfile.productionLean,
          ),
          child: child!,
        ),
        home: const Scaffold(body: Text('Automatically private')),
      ),
    );

    await _waitForCaptures(tester);
    final session = TugboatReplay.controller!.session!;
    expect(session.frames.single.masked, isTrue);
    final encoded = session.frameBytes[session.frames.single.id]!;
    final image = img.decodePng(encoded)!;
    final textCenter = tester.getCenter(find.text('Automatically private'));
    final pixel = image.getPixel(textCenter.dx.round(), textCenter.dy.round());
    expect(pixel.r, closeTo(0x1a, 2));
    expect(pixel.g, closeTo(0x1a, 2));
    expect(pixel.b, closeTo(0x1a, 2));
  });

  testWidgets('allTextExceptActionable leaves button labels visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(
            screenshotMaskLevel:
                TugboatScreenshotMaskLevel.allTextExceptActionable,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Continue')),
        ),
      ),
    );

    await _waitForCaptures(tester);
    expect(TugboatReplay.controller!.session!.frames.single.masked, isFalse);
  });

  testWidgets('exploration action window annotates captured events', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Act')),
        ),
      ),
    );
    await _waitForCaptures(tester);

    final controller = TugboatReplay.controller!;
    controller.setExplorationActionWindow(
      explorationRunId: 'run-1',
      actionId: 'A-1',
    );
    await tester.tap(find.text('Act'));
    await _waitForCaptures(tester);
    controller.clearExplorationActionWindow();

    final actionEvents = controller.session!.events
        .where((event) => event.actionId == 'A-1')
        .toList();
    expect(actionEvents, isNotEmpty);
    expect(
      actionEvents.every((event) => event.explorationRunId == 'run-1'),
      isTrue,
    );
  });

  testWidgets('does not record icon or tooltip labels on icon button taps', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: IconButton(
            tooltip: 'Notifications',
            onPressed: () {},
            icon: const Icon(Icons.notifications_outlined),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);
    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await _waitForCaptures(tester);

    final anchor = TugboatReplay.controller!.session!.events
        .firstWhere((event) => event.type == 'tap')
        .targetAnchor!;
    expect(anchor.role, 'button');
    expect(anchor.fingerprint, isNotNull);
    expect(_containsLabelTelemetry(anchor.toJson()), isFalse);
  });

  testWidgets('does not record descendant labels from list tile taps', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: ListTile(
            title: const Text('Product catalog'),
            subtitle: const Text('Browse items'),
            onTap: () {},
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);
    await tester.tap(find.byType(ListTile));
    await _waitForCaptures(tester);

    final anchor = TugboatReplay.controller!.session!.events
        .firstWhere((event) => event.type == 'tap')
        .targetAnchor!;
    expect(anchor.role, 'button');
    expect(_containsLabelTelemetry(anchor.toJson()), isFalse);
  });

  test('session round-trips through JSON', () {
    const appInfo = TugboatCollectorAppInfo(
      name: 'Example App',
      version: '1.2.3',
      buildNumber: '42',
      installationId: 'install-1',
    );
    final session = TugboatSession(
      id: 's1',
      startedAt: DateTime.utc(2026, 6, 15),
      platform: 'test',
      viewport: const TugboatRect(0, 0, 100, 200),
      appInfo: appInfo,
    );
    session.frames.add(
      const TugboatFrame(
        id: 'frame-0',
        atMs: 0,
        width: 100,
        height: 200,
        contentHash: 'abc',
        trigger: TugboatFrameTrigger.initial,
        byteLength: 1024,
        captureMicros: 12345,
      ),
    );
    session.events.add(
      const TugboatEvent(id: 'event-0', atMs: 0, type: 'session_start'),
    );

    final json = jsonDecode(session.toPrettyJson()) as Map<String, dynamic>;
    expect(json['schemaVersion'], 6);
    expect(json.containsKey('routes'), isFalse);
    expect(json['events'], [isNot(contains('route'))]);
    expect(json['frames'], [containsPair('captureMicros', 12345)]);
    expect((json['session'] as Map)['appInfo'], appInfo.toJson());
    final restored = TugboatSessionTestJson.fromJson(json);
    expect(restored.appInfo?.buildNumber, '42');
    expect(restored.frames.length, 1);
    expect(restored.frames.single.captureMicros, 12345);
  });

  test('session rejects old or missing schema versions', () {
    final session = TugboatSession(
      id: 's1',
      startedAt: DateTime.utc(2026, 6, 15),
      platform: 'test',
      viewport: const TugboatRect(0, 0, 100, 200),
    );
    final json = session.toJson();

    expect(
      () => TugboatSessionTestJson.fromJson({...json, 'schemaVersion': 5}),
      throwsFormatException,
    );
    final withoutVersion = Map<String, Object?>.from(json)
      ..remove('schemaVersion');
    expect(
      () => TugboatSessionTestJson.fromJson(withoutVersion),
      throwsFormatException,
    );
  });

  test('frame JSON defaults missing capture timing for older sessions', () {
    final frame = TugboatFrameTestJson.fromJson({
      'id': 'frame-0',
      'atMs': 0,
      'width': 100,
      'height': 200,
      'contentHash': 'abc',
    });

    expect(frame.captureMicros, 0);
  });

  test('target anchor round-trips through JSON', () {
    const anchor = TugboatTargetAnchor(
      widgetType: 'FilledButton',
      role: 'button',
      fingerprint: 'stable-target',
      fingerprintConfidence: 'high',
      tagFingerprint: 'stable-tag',
      canonicalPath: 'Scaffold#0/FilledButton#0',
      fingerprintParts: {
        'role': 'button',
        'widgetType': 'FilledButton',
        'relativePosition': 'bottom',
        'enabled': 'true',
        'actions': 'tap',
      },
      relativePosition: 'bottom',
      enabled: true,
      actions: ['tap'],
    );
    final restored = TugboatTargetAnchorTestJson.fromJson(anchor.toJson());
    expect(restored.fingerprint, 'stable-target');
    expect(restored.fingerprintConfidence, 'high');
    expect(restored.tagFingerprint, 'stable-tag');
    expect(restored.canonicalPath, 'Scaffold#0/FilledButton#0');
    expect(restored.fingerprintParts, containsPair('actions', 'tap'));
    expect(restored.relativePosition, 'bottom');
    expect(restored.enabled, isTrue);
    expect(restored.actions, ['tap']);
    expect(_containsLabelTelemetry(anchor.toJson()), isFalse);
    expect(anchor.toJson().containsKey('labelHash'), isFalse);
    expect(anchor.toJson().containsKey('bounds'), isFalse);
    expect(anchor.toJson().containsKey('itemIndex'), isFalse);
  });

  testWidgets('state signatures ignore dynamic visible labels', (tester) async {
    final rootKey = GlobalKey();

    Future<TugboatStateAnchor> buildAnchor(String label) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: Column(
                children: [
                  Text(label),
                  FilledButton(onPressed: () {}, child: const Text('Continue')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return AnchorResolver(rootKey: rootKey).buildStateAnchor(
        route: '/intro',
        keyboardOpen: false,
        modalOpen: false,
      );
    }

    final first = await buildAnchor('Brooke Martins');
    final second = await buildAnchor('Alex Chen');

    expect(first.signature, second.signature);
    expect(first.signatureConfidence, isNotNull);
    expect(first.signatureParts, containsPair('routeKey', '/intro'));
    expect(first.signatureParts.containsKey('labels'), isFalse);
    expect(_containsLabelTelemetry(first.toJson()), isFalse);
  });

  testWidgets('target fingerprints ignore dynamic button labels', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<TugboatTargetAnchor> targetAnchor(String label) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: Center(
                child: FilledButton(onPressed: () {}, child: Text(label)),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final center = tester.getCenter(find.byType(FilledButton));
      return AnchorResolver(rootKey: rootKey).targetAt(center)!;
    }

    final first = await targetAnchor('Continue');
    final second = await targetAnchor('Start trial');

    expect(first.fingerprint, second.fingerprint);
    expect(first.fingerprintConfidence, isNotNull);
    expect(first.fingerprintParts.containsKey('descendantLabels'), isFalse);
    expect(_containsLabelTelemetry(first.toJson()), isFalse);
  });

  test('exploration context round-trips through event JSON', () {
    const event = TugboatEvent(
      id: 'event-1',
      atMs: 10,
      type: 'tap',
      sessionId: 's1',
      explorationRunId: 'run-1',
      actionId: 'A-1',
    );
    final restored = TugboatEventTestJson.fromJson(event.toJson());
    expect(restored.sessionId, 's1');
    expect(restored.toJson().containsKey('route'), isFalse);
    expect(restored.explorationRunId, 'run-1');
    expect(restored.actionId, 'A-1');
  });

  testWidgets('disabled SDK passes through child without capture', (
    tester,
  ) async {
    addTearDown(() {
      TugboatReplay.disabled = false;
      TugboatReplay.deactivate();
    });

    TugboatReplay.disabled = true;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: const Scaffold(body: Text('Disabled')),
      ),
    );
    await _waitForCaptures(tester);

    expect(TugboatReplay.isEnabled, isFalse);
    expect(TugboatReplay.controller, isNull);
    expect(find.text('Disabled'), findsOneWidget);

    TugboatReplay.activate(
      sessionId: 'session-disabled',
      profile: TugboatCaptureProfile.exploration,
    );
    expect(TugboatReplay.isActivated, isFalse);
  });

  testWidgets('dormant profile passes through child until activated', (
    tester,
  ) async {
    addTearDown(TugboatReplay.deactivate);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(child: child!),
        home: const Scaffold(body: Text('Dormant')),
      ),
    );
    await tester.pump();

    expect(TugboatReplay.controller, isNull);
    expect(find.text('Dormant'), findsOneWidget);

    TugboatReplay.activate(
      sessionId: 'session-1',
      profile: TugboatCaptureProfile.exploration,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(profile: TugboatCaptureProfile.dormant),
          child: child!,
        ),
        home: const Scaffold(body: Text('Active')),
      ),
    );
    await _waitForCaptures(tester);
    expect(TugboatReplay.controller, isNotNull);
    expect(
      TugboatReplay.controller!.config.profile,
      TugboatCaptureProfile.exploration,
    );
  });

  test('perceptual hash is stable for identical rgba input', () {
    final rgba = Uint8List.fromList(List<int>.filled(4 * 8 * 8, 128));
    final first = computeDHashFromRgba(rgba, 8, 8);
    final second = computeDHashFromRgba(rgba, 8, 8);
    expect(first, second);
    expect(first.length, 64);
  });

  testWidgets('skips tap capture when route capture is pending', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: const SizedBox(width: 100, height: 100),
      ),
    );
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: rootKey,
    );
    await controller.initialize();
    controller.start(const Size(100, 100), 'test');
    await tester.pump();
    final framesBefore = controller.session!.frames.length;

    await tester.runAsync(() async {
      unawaited(
        controller.route(
          'route_push',
          PageRouteBuilder<void>(
            settings: const RouteSettings(name: '/next'),
            transitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      );
      controller.recordPointerDown(const Offset(10, 10), pointer: 1);
      controller.recordPointerUp(const Offset(10, 10), pointer: 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(controller.session!.frames.length, framesBefore);
    controller.dispose();
  });

  testWidgets('scroll_end forces after-frame capture when samples disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(captureScrollSamples: false),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            children: const [
              SizedBox(height: 80, child: Text('Row 0')),
              SizedBox(height: 80, child: Text('Row 1')),
            ],
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    final session = TugboatReplay.controller!.session!;
    final framesBeforeScroll = session.frames.length;

    await tester.drag(find.byType(ListView), const Offset(0, -40));
    await _waitForCaptures(tester);

    final scrollEnds = session.events
        .where((event) => event.type == 'scroll_end')
        .toList();
    expect(scrollEnds, isNotEmpty);
    expect(scrollEnds.last.afterFrame, isNotNull);
    expect(session.frames.length, greaterThanOrEqualTo(framesBeforeScroll));
  });

  test('tap_settled result prefers signature change over stale frame ids', () {
    final rootKey = GlobalKey();
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: rootKey,
    );

    final result = controller.debugComputeTapSettleResult(
      beforeState: const TugboatStateAnchor(signature: 'sig-before'),
      afterState: const TugboatStateAnchor(signature: 'sig-after'),
      beforeFrame: 'frame-1',
      afterFrame: 'frame-1',
    );
    expect(result, TugboatInteractionResult.changed);
    controller.dispose();
  });

  test('tap_settled result uses tap-down baseline signatures', () {
    final rootKey = GlobalKey();
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: rootKey,
    );

    final result = controller.debugComputeTapSettleResult(
      beforeState: const TugboatStateAnchor(signature: 'home-sig'),
      afterState: const TugboatStateAnchor(signature: 'route-sig'),
      beforeFrame: 'frame-1',
      afterFrame: 'frame-1',
    );
    expect(result, TugboatInteractionResult.changed);
    controller.dispose();
  });

  test('a throwing queued task does not poison later tap settles', () async {
    final rootKey = GlobalKey();
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: rootKey,
    );
    await controller.initialize();
    controller.start(const Size(100, 100), 'test');
    controller.debugSetExplorationFramesSuppressed(true);

    unawaited(
      controller.debugEnqueueTask('test_failure', () async {
        throw StateError('simulated capture failure');
      }),
    );

    controller.recordPointerDown(const Offset(5, 5), pointer: 1);
    controller.recordPointerUp(const Offset(5, 5), pointer: 1);
    await controller.drainPointerQueue();

    final settles = controller.session!.events
        .where((event) => event.type == 'tap_settled')
        .toList();
    expect(settles, hasLength(1));
    controller.dispose();
  });

  test('overlapping taps keep pointer-specific relatedEventId links', () async {
    final rootKey = GlobalKey();
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: rootKey,
    );
    await controller.initialize();
    controller.start(const Size(100, 100), 'test');
    controller.debugSetExplorationFramesSuppressed(true);

    controller.recordPointerDown(const Offset(1, 1), pointer: 1);
    controller.recordPointerDown(const Offset(2, 2), pointer: 2);
    controller.recordPointerUp(const Offset(1, 1), pointer: 1);
    controller.recordPointerUp(const Offset(2, 2), pointer: 2);
    await controller.drainPointerQueue();

    final taps = controller.session!.events
        .where((event) => event.type == 'tap')
        .toList();
    final settles = controller.session!.events
        .where((event) => event.type == 'tap_settled')
        .toList();
    expect(taps, hasLength(2));
    expect(settles, hasLength(2));
    expect(settles[0].relatedEventId, taps[0].id);
    expect(settles[1].relatedEventId, taps[1].id);
    controller.dispose();
  });
}
