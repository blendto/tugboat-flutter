import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tugboat/tugboat.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/capture_boundary.dart';
import 'package:tugboat/src/perceptual_hash.dart'
    show computeDHashFromRgba, dHashHammingDistance, dHashVisuallyMatches;
import 'package:tugboat/src/screenshot_encode.dart';

import 'helpers/json_roundtrip.dart';

const _testConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  interactionPublishMode: TugboatInteractionPublishMode.dualWrite,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
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

/// Drive both Flutter frames and the real async queue until [future] resolves.
/// Screenshot readback starts after end-of-frame, so a single delayed pump can
/// otherwise leave a fresh attempt waiting for its next compositor turn.
Future<T> _waitForCaptureResolution<T>(
  WidgetTester tester,
  Future<T> future,
) async {
  final resolution = Completer<T>();
  unawaited(
    future.then(resolution.complete, onError: resolution.completeError),
  );
  for (var attempt = 0; attempt < 60; attempt++) {
    if (resolution.isCompleted) return resolution.future;
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(resolution.isCompleted, isTrue, reason: 'capture did not resolve');
  return resolution.future;
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

  testWidgets('app background and foreground transitions are explicit', (
    tester,
  ) async {
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
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    final lifecycleEvents = session.events
        .where(
          (event) =>
              event.type == 'app_backgrounded' ||
              event.type == 'app_foregrounded',
        )
        .toList();
    expect(lifecycleEvents.length, greaterThanOrEqualTo(2));
    expect(
      lifecycleEvents.map((event) => event.type),
      containsAllInOrder(['app_backgrounded', 'app_foregrounded']),
    );
    expect(
      lifecycleEvents.map((event) => event.data['state']),
      containsAllInOrder(['paused', 'resumed']),
    );
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

    final framesBeforeTap = session.frames.length;
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
    expect(session.frames.length, greaterThan(framesBeforeTap));
    expect(settled.first.afterFrame, isNot(tapEvents.first.beforeFrame));
  });

  testWidgets(
    'completed interaction bypasses reuse gates with an unchanged compatible frame',
    (tester) async {
      final rootKey = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: TugboatCaptureBoundary(
              key: rootKey,
              child: const SizedBox.square(dimension: 80),
            ),
          ),
        ),
      );
      final controller = TugboatReplayController(
        config: _testConfig,
        boundaryKey: rootKey,
      )..debugScreenshotEncoder = InlineScreenshotEncoder();
      await controller.initialize();
      controller.start(const Size(80, 80), 'test');

      final baselineCapture = controller.debugRequestCapture(
        trigger: TugboatFrameTrigger.manual,
        force: true,
      );
      final baselineResolution = await _waitForCaptureResolution(
        tester,
        baselineCapture.resolution,
      );
      expect(baselineResolution['outcome'], 'fresh_accepted');
      final baselineFrameId = baselineResolution['frameId']! as String;
      final baselineFrame = controller.session!.frames.singleWhere(
        (frame) => frame.id == baselineFrameId,
      );
      final boundary =
          rootKey.currentContext!.findRenderObject()!
              as TugboatCaptureRenderBoundary;
      final acceptedGeneration = boundary.paintGeneration;

      // The seeded frame is compatible and the subtree has not changed. This
      // also simulates the local exploration WebSocket's non-interaction
      // suppression. A completed pointer interaction must still capture.
      controller.debugSetExplorationFramesSuppressed(true);
      expect(boundary.paintGeneration, acceptedGeneration);
      final framesBeforeInteraction = controller.session!.frames.length;
      controller.recordPointerDown(const Offset(40, 40), pointer: 7);
      controller.recordPointerUp(const Offset(40, 40), pointer: 7);
      for (var attempt = 0; attempt < 60; attempt++) {
        final hasInteractionDiagnostic = controller.session!.events.any(
          (event) =>
              event.type == 'capture_diagnostic' &&
              event.data['trigger'] == 'interaction',
        );
        if (hasInteractionDiagnostic) break;
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }

      final interactionDiagnostics = controller.session!.events
          .where(
            (event) =>
                event.type == 'capture_diagnostic' &&
                event.data['trigger'] == 'interaction',
          )
          .toList(growable: false);
      expect(interactionDiagnostics, hasLength(1));
      final diagnostic = interactionDiagnostics.single;
      expect(diagnostic.data['outcome'], 'fresh_accepted');
      expect(diagnostic.data.containsKey('reuseReason'), isFalse);
      expect(diagnostic.data.containsKey('coalesced'), isFalse);
      expect(
        controller.session!.frames,
        hasLength(framesBeforeInteraction + 1),
      );
      final freshFrame = controller.session!.frames.last;
      expect(freshFrame.id, isNot(baselineFrame.id));
      expect(
        freshFrame.contentHash,
        baselineFrame.contentHash,
        reason:
            'identical pixels must not resolve through dHash or content-hash reuse',
      );
      controller.dispose();
    },
  );

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
            backgroundColor: Colors.red,
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: '/next'),
                  builder: (_) => const Scaffold(
                    backgroundColor: Colors.blue,
                    body: Text('Next screen'),
                  ),
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
    expect(routeChangeJson.containsKey('stateAnchor'), isFalse);
    expect(session.frames, isNotEmpty);
    expect(routeChange.afterFrame, isNotNull);
    final routeBytes = session.frameBytes[routeChange.afterFrame]!;
    final routeImage = img.decodeJpg(routeBytes)!;
    final routePixel = routeImage.getPixel(
      routeImage.width ~/ 2,
      routeImage.height ~/ 2,
    );
    expect(routePixel.b, greaterThan(routePixel.r));

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
    expect(changes[0].data, containsPair('route', '/a'));
    expect(changes[0].data, containsPair('navigation', 'route_push'));
    expect(changes[1].data, containsPair('fromRoute', '/a'));
    expect(changes[1].data, containsPair('route', '/b'));
    expect(changes[1].data, containsPair('navigation', 'route_replace'));
    expect(changes[2].data, containsPair('fromRoute', '/b'));
    expect(changes[2].data, containsPair('route', '/a'));
    expect(changes[2].data, containsPair('navigation', 'route_pop'));
    expect(changes[3].data, containsPair('fromRoute', '/a'));
    expect(changes[3].data, containsPair('route', '/b'));
    expect(changes[3].data, containsPair('navigation', 'route_remove'));
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
    expect(changes[0].data, containsPair('route', '/'));
    expect(changes[0].data, containsPair('navigation', 'route_push'));
    expect(changes[1].data, containsPair('fromRoute', '/'));
    expect(changes[1].data, containsPair('route', '/intro'));
    expect(changes[1].data, containsPair('navigation', 'route_push'));
    controller.dispose();
  });

  testWidgets('stack cleanup keeps the pending destination capture', (
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
        interactionClaimWindow: Duration.zero,
        enableGlobalPointerCapture: false,
        capturePixelRatio: 1.0,
      ),
      boundaryKey: rootKey,
    );
    controller.start(const Size(390, 844), 'test');

    PageRoute<void> route(String name, Duration transition) =>
        PageRouteBuilder<void>(
          settings: RouteSettings(name: name),
          transitionDuration: transition,
          pageBuilder: (_, _, _) => const SizedBox.shrink(),
        );

    await tester.runAsync(() async {
      await controller.route('route_push', route('/old', Duration.zero));
      final pushFuture = controller.route(
        'route_push',
        route('/home', const Duration(milliseconds: 200)),
      );
      // pushNamedAndRemoveUntil cleanup: didRemove reports the new top as
      // the still-visible route while the push capture is pending.
      await controller.route('route_remove', route('/home', Duration.zero));
      await pushFuture;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    final changes = controller.session!.events
        .where((event) => event.type == 'route_change')
        .toList();
    expect(changes.map((event) => event.data['navigation']), [
      'route_push',
      'route_push',
    ]);
    expect(changes.last.data, containsPair('fromRoute', '/old'));
    expect(changes.last.data, containsPair('route', '/home'));
    expect(changes.last.data, containsPair('navigation', 'route_push'));
    expect(controller.currentRoute, '/home');
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
        interactionClaimWindow: Duration.zero,
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
    final image = img.decodeImage(encoded)!;
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

  testWidgets('nonAssetImagesOnly leaves bundled asset images visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(
            screenshotMaskLevel: TugboatScreenshotMaskLevel.nonAssetImagesOnly,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: Image.asset(
                'test/assets/red_square.png',
                fit: BoxFit.fill,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage('test/assets/red_square.png'),
        tester.element(find.byType(Scaffold)),
      );
    });
    await tester.pump();

    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final frame = session.frames.last;
    expect(frame.masked, isFalse);
    final image = img.decodeImage(session.frameBytes[frame.id]!)!;
    final center = tester.getCenter(find.byType(Image));
    final pixel = image.getPixel(center.dx.round(), center.dy.round());
    expect(pixel.r, greaterThan(0xc0));
    expect(pixel.g, lessThan(0x40));
  });

  testWidgets('nonAssetImagesOnly masks memory images', (tester) async {
    final green = img.Image(width: 8, height: 8);
    img.fill(green, color: img.ColorRgb8(0, 255, 0));
    final imageBytes = Uint8List.fromList(img.encodePng(green));
    final provider = MemoryImage(imageBytes);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(
            screenshotMaskLevel: TugboatScreenshotMaskLevel.nonAssetImagesOnly,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: Image(image: provider, fit: BoxFit.fill),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(provider, tester.element(find.byType(Scaffold)));
    });
    await tester.pump();

    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final frame = session.frames.last;
    expect(frame.masked, isTrue);
    final image = img.decodeImage(session.frameBytes[frame.id]!)!;
    final center = tester.getCenter(find.byType(Image));
    final pixel = image.getPixel(center.dx.round(), center.dy.round());
    expect(pixel.r, closeTo(0x1a, 2));
    expect(pixel.g, closeTo(0x1a, 2));
    expect(pixel.b, closeTo(0x1a, 2));
  });

  testWidgets('nonAssetImagesOnly still masks TugboatSensitive asset images', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(
            screenshotMaskLevel: TugboatScreenshotMaskLevel.nonAssetImagesOnly,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: TugboatSensitive(
              child: SizedBox(
                width: 64,
                height: 64,
                child: Image.asset(
                  'test/assets/red_square.png',
                  fit: BoxFit.fill,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage('test/assets/red_square.png'),
        tester.element(find.byType(Scaffold)),
      );
    });
    await tester.pump();

    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final frame = session.frames.last;
    expect(frame.masked, isTrue);
    final image = img.decodeImage(session.frameBytes[frame.id]!)!;
    final center = tester.getCenter(find.byType(Image));
    final pixel = image.getPixel(center.dx.round(), center.dy.round());
    expect(pixel.r, closeTo(0x1a, 2));
    expect(pixel.g, closeTo(0x1a, 2));
    expect(pixel.b, closeTo(0x1a, 2));
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

  testWidgets('canonical interaction keeps its pointer-down action window', (
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
      actionId: 'A-origin',
    );
    await tester.tap(find.text('Act'));
    controller.setExplorationActionWindow(
      explorationRunId: 'run-1',
      actionId: 'A-next',
    );
    await _waitForCaptures(tester);

    final interaction = controller.session!.events.singleWhere(
      (event) => event.type == 'interaction',
    );
    expect(interaction.actionId, 'A-origin');
    expect(interaction.explorationRunId, 'run-1');
    expect((interaction.data['origin'] as Map)['actionId'], 'A-origin');
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

  testWidgets('does not emit control or semantic value telemetry', (
    tester,
  ) async {
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Switch(
              value: enabled,
              onChanged: (next) => setState(() => enabled = next),
            ),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);
    await tester.tap(find.byType(Switch));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final tap = session.events.firstWhere((event) => event.type == 'tap');
    final settled = session.events.firstWhere(
      (event) => event.type == 'tap_settled' && event.relatedEventId == tap.id,
    );
    expect(enabled, isTrue);
    expect(tap.targetAnchor, isNotNull);
    expect(settled.targetAnchor, isNotNull);
    for (final event in [tap, settled]) {
      expect(event.data.containsKey('controlValue'), isFalse);
      expect(event.data.containsKey('controlValueTransition'), isFalse);
      expect(event.data.containsKey('semanticAnnotation'), isFalse);
    }

    final sessionJson = jsonEncode(session.toJson());
    expect(sessionJson, isNot(contains('"controlValue"')));
    expect(sessionJson, isNot(contains('"controlValueTransition"')));
    expect(sessionJson, isNot(contains('"semanticAnnotation"')));
  });

  test('session round-trips through JSON', () {
    const appInfo = TugboatCollectorAppInfo(
      name: 'Example App',
      version: '1.2.3',
      buildNumber: '42',
      installationId: 'install-1',
      appId: 'com.example.app',
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
    expect(json['schemaVersion'], 9);
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
      TugboatReplay.resetForTest();
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
      activationRequestId: 'session-disabled',
      profile: TugboatCaptureProfile.exploration,
    );
    expect(TugboatReplay.isActivated, isFalse);
  });

  testWidgets('dormant profile stays inert until activated without rebuild', (
    tester,
  ) async {
    addTearDown(TugboatReplay.resetForTest);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(profile: TugboatCaptureProfile.dormant),
          child: child!,
        ),
        home: const Scaffold(body: Text('Dormant')),
      ),
    );
    await tester.pump();

    expect(TugboatReplay.controller, isNull);
    expect(find.text('Dormant'), findsOneWidget);
    expect(TugboatReplay.boundaryKey.currentContext, isNull);

    TugboatReplay.activate(
      activationRequestId: 'request-1',
      profile: TugboatCaptureProfile.exploration,
    );
    await _waitForCaptures(tester);

    expect(TugboatReplay.controller, isNotNull);
    expect(TugboatReplay.activationRequestId, 'request-1');
    expect(
      TugboatReplay.controller!.config.profile,
      TugboatCaptureProfile.exploration,
    );
    expect(TugboatReplay.controller!.session!.activationRequestId, 'request-1');
    expect(TugboatReplay.controller!.session!.id, isNot(equals('request-1')));
  });

  testWidgets('activate-deactivate-activate ends each session once', (
    tester,
  ) async {
    addTearDown(TugboatReplay.resetForTest);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(profile: TugboatCaptureProfile.dormant),
          child: child!,
        ),
        home: const Scaffold(body: Text('Gate')),
      ),
    );
    await tester.pump();

    TugboatReplay.activate(
      activationRequestId: 'req-a',
      profile: TugboatCaptureProfile.exploration,
    );
    await _waitForCaptures(tester);
    final firstId = TugboatReplay.controller!.session!.id;

    TugboatReplay.deactivate();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(TugboatReplay.controller, isNull);

    TugboatReplay.activate(
      activationRequestId: 'req-b',
      profile: TugboatCaptureProfile.exploration,
    );
    await _waitForCaptures(tester);
    final secondId = TugboatReplay.controller!.session!.id;
    expect(secondId, isNot(equals(firstId)));
    expect(TugboatReplay.activationRequestId, 'req-b');
  });

  testWidgets(
    'config userId applies on remount when setUserId was never called',
    (tester) async {
      addTearDown(TugboatReplay.resetForTest);

      late HttpServer server;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          request.response
            ..statusCode = 202
            ..write(jsonEncode({'accepted': true, 'sessionId': 'sess_server'}));
          await request.response.close();
        });
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      TugboatCollectorConfig collectorConfig() => TugboatCollectorConfig(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'pmk_test',
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

      Future<void> pumpWithUserId(String userId) async {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => TugboatReplay.wrapApp(
              config: _testConfig.copyWith(
                profile: TugboatCaptureProfile.dormant,
                userId: userId,
                collector: collectorConfig(),
              ),
              child: child!,
            ),
            home: const Scaffold(body: Text('Identity')),
          ),
        );
        await tester.pump();
      }

      await pumpWithUserId('user_a');
      TugboatReplay.activate(
        activationRequestId: 'req-user-a',
        profile: TugboatCaptureProfile.exploration,
      );
      await _waitForCaptures(tester);
      expect(TugboatReplay.controller!.collectorUserId, 'user_a');
      expect(TugboatReplay.hasPendingUserIdOverride, isFalse);

      TugboatReplay.deactivate();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(TugboatReplay.controller, isNull);
      expect(TugboatReplay.hasPendingUserIdOverride, isFalse);

      await pumpWithUserId('user_b');
      TugboatReplay.activate(
        activationRequestId: 'req-user-b',
        profile: TugboatCaptureProfile.exploration,
      );
      await _waitForCaptures(tester);
      expect(TugboatReplay.controller!.collectorUserId, 'user_b');
      expect(TugboatReplay.hasPendingUserIdOverride, isFalse);
    },
  );

  testWidgets('setUserId override survives remount over config userId', (
    tester,
  ) async {
    addTearDown(TugboatReplay.resetForTest);

    late HttpServer server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response
          ..statusCode = 202
          ..write(jsonEncode({'accepted': true, 'sessionId': 'sess_server'}));
        await request.response.close();
      });
    });
    addTearDown(() async {
      await server.close(force: true);
    });

    TugboatCollectorConfig collectorConfig() => TugboatCollectorConfig(
      baseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'pmk_test',
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

    Future<void> pumpWithUserId(String userId) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => TugboatReplay.wrapApp(
            config: _testConfig.copyWith(
              profile: TugboatCaptureProfile.dormant,
              userId: userId,
              collector: collectorConfig(),
            ),
            child: child!,
          ),
          home: const Scaffold(body: Text('Override')),
        ),
      );
      await tester.pump();
    }

    await pumpWithUserId('user_a');
    TugboatReplay.activate(
      activationRequestId: 'req-override-a',
      profile: TugboatCaptureProfile.exploration,
    );
    await _waitForCaptures(tester);
    await tester.runAsync(() => TugboatReplay.setUserId('runtime'));
    expect(TugboatReplay.controller!.collectorUserId, 'runtime');
    expect(TugboatReplay.hasPendingUserIdOverride, isTrue);

    TugboatReplay.deactivate();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(TugboatReplay.controller, isNull);
    expect(TugboatReplay.hasPendingUserIdOverride, isTrue);
    expect(TugboatReplay.pendingUserId, 'runtime');

    await pumpWithUserId('user_b');
    TugboatReplay.activate(
      activationRequestId: 'req-override-b',
      profile: TugboatCaptureProfile.exploration,
    );
    await _waitForCaptures(tester);
    expect(TugboatReplay.controller!.collectorUserId, 'runtime');
    expect(TugboatReplay.hasPendingUserIdOverride, isTrue);
  });

  testWidgets('identical activate request is idempotent', (tester) async {
    addTearDown(TugboatReplay.resetForTest);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig.copyWith(profile: TugboatCaptureProfile.dormant),
          child: child!,
        ),
        home: const Scaffold(body: Text('Idempotent')),
      ),
    );
    await tester.pump();

    TugboatReplay.activate(
      activationRequestId: 'same',
      profile: TugboatCaptureProfile.exploration,
    );
    await _waitForCaptures(tester);
    final sessionId = TugboatReplay.controller!.session!.id;
    final epoch = TugboatReplay.lifecycle.requestEpoch;

    TugboatReplay.activate(
      activationRequestId: 'same',
      profile: TugboatCaptureProfile.exploration,
    );
    await tester.pump();
    expect(TugboatReplay.lifecycle.requestEpoch, epoch);
    expect(TugboatReplay.controller!.session!.id, sessionId);
  });

  test('perceptual hash is stable for identical rgba input', () {
    final rgba = Uint8List.fromList(List<int>.filled(4 * 8 * 8, 128));
    final first = computeDHashFromRgba(rgba, 8, 8);
    final second = computeDHashFromRgba(rgba, 8, 8);
    expect(first, second);
    expect(first.length, 64);
  });

  test('perceptual hash match tolerates small hamming distance', () {
    final base = '0' * 64;
    final oneBit = '1${'0' * 63}';
    final twoBits = '11${'0' * 62}';
    final threeBits = '111${'0' * 61}';
    expect(dHashHammingDistance(base, oneBit), 1);
    expect(dHashVisuallyMatches(base, oneBit), isTrue);
    expect(dHashVisuallyMatches(base, twoBits), isTrue);
    expect(dHashVisuallyMatches(base, threeBits), isFalse);
  });

  test('perceptual hash aggregates cell pixels on large buffers', () {
    const width = 80;
    const height = 80;
    final rgba = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final offset = (y * width + x) * 4;
        final isCorner = x < width ~/ 8 && y < height ~/ 8;
        final gray = isCorner ? 0 : 200;
        rgba[offset] = gray;
        rgba[offset + 1] = gray;
        rgba[offset + 2] = gray;
        rgba[offset + 3] = 255;
      }
    }
    final uniform = computeDHashFromRgba(
      Uint8List.fromList(List<int>.filled(width * height * 4, 200)),
      width,
      height,
    );
    final withCorner = computeDHashFromRgba(rgba, width, height);
    expect(withCorner, isNot(uniform));
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

  test('tap_settled result does not infer a change from state signatures', () {
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
      targetAnchor: const TugboatTargetAnchor(actions: ['tap']),
    );
    expect(result, TugboatInteractionResult.unknown);
    controller.dispose();
  });

  test('tap_settled result ignores tap-down state signatures', () {
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
      targetAnchor: const TugboatTargetAnchor(actions: ['tap']),
    );
    expect(result, TugboatInteractionResult.unknown);
    controller.dispose();
  });

  test('tap_settled does not claim a no-op without visual evidence', () {
    final rootKey = GlobalKey();
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: rootKey,
    );

    final result = controller.debugComputeTapSettleResult(
      beforeState: const TugboatStateAnchor(signature: 'same-sig'),
      afterState: const TugboatStateAnchor(signature: 'same-sig'),
      beforeFrame: null,
      afterFrame: 'frame-without-evidence',
      targetAnchor: const TugboatTargetAnchor(actions: ['tap']),
    );
    expect(result, TugboatInteractionResult.unknown);
    controller.dispose();
  });

  test('tap_settled ignores ambient frame changes on non-tappable targets', () {
    final rootKey = GlobalKey();
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: rootKey,
    );
    controller.start(const Size(100, 100), 'test');
    controller.session!.frames.addAll(const [
      TugboatFrame(
        id: 'frame-before',
        atMs: 1,
        width: 100,
        height: 100,
        contentHash: 'before-hash',
      ),
      TugboatFrame(
        id: 'frame-after',
        atMs: 2,
        width: 100,
        height: 100,
        contentHash: 'after-hash',
      ),
    ]);

    final result = controller.debugComputeTapSettleResult(
      beforeState: const TugboatStateAnchor(signature: 'same-sig'),
      afterState: const TugboatStateAnchor(signature: 'same-sig'),
      beforeFrame: 'frame-before',
      afterFrame: 'frame-after',
      targetAnchor: const TugboatTargetAnchor(
        role: 'scrollable',
        actions: ['scroll'],
      ),
    );

    expect(result, TugboatInteractionResult.noVisibleChange);
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
