import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat/src/input_capture.dart';
import 'package:tugboat/src/interaction_transaction.dart';

import '../helpers/replay_coherence_harness.dart';

void main() {
  test('pinch-out past scale slop is zoom_in', () {
    expect(
      classifyPointerScaleGesture(
        startSpan: 100,
        currentSpan: 130,
        startCentroid: const Offset(50, 50),
        currentCentroid: const Offset(50, 50),
      ),
      InteractionGesture.zoomIn,
    );
  });

  test('pinch-in past scale slop is zoom_out', () {
    expect(
      classifyPointerScaleGesture(
        startSpan: 100,
        currentSpan: 70,
        startCentroid: const Offset(50, 50),
        currentCentroid: const Offset(50, 50),
      ),
      InteractionGesture.zoomOut,
    );
  });

  test('shared two-pointer translation past pan slop is pan', () {
    expect(
      classifyPointerScaleGesture(
        startSpan: 100,
        currentSpan: 100,
        startCentroid: const Offset(50, 50),
        currentCentroid: const Offset(50, 100),
      ),
      InteractionGesture.pan,
    );
  });

  test('sub-slop two-pointer motion is unclassified', () {
    expect(
      classifyPointerScaleGesture(
        startSpan: 100,
        currentSpan: 105,
        startCentroid: const Offset(50, 50),
        currentCentroid: const Offset(52, 51),
      ),
      isNull,
    );
  });

  test('trackpad scale above ratio is zoom_in', () {
    expect(
      classifyTrackpadPanZoom(scale: 1.2, pan: Offset.zero),
      InteractionGesture.zoomIn,
    );
  });

  test('trackpad scale below inverse ratio is zoom_out', () {
    expect(
      classifyTrackpadPanZoom(scale: 0.8, pan: Offset.zero),
      InteractionGesture.zoomOut,
    );
  });

  test('trackpad pan without scale is pan', () {
    expect(
      classifyTrackpadPanZoom(scale: 1.0, pan: const Offset(0, 48)),
      InteractionGesture.pan,
    );
  });

  test('InputCapture pinch-out records one zoom_in', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );

    capture.handlePointerDown(
      const PointerDownEvent(pointer: 1, position: Offset(140, 200)),
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 2, position: Offset(220, 200)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(90, 200)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 2, position: Offset(270, 200)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 1, position: Offset(90, 200)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 2, position: Offset(270, 200)),
    );
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(1));
    expect(interactions.single.data['gesture'], 'zoom_in');
    final payload = Map<String, Object?>.from(
      interactions.single.data['payload']! as Map,
    );
    expect(payload['pointerCount'], 2);
    expect(payload['scale'], greaterThan(1));
  });

  test('InputCapture pinch-in records one zoom_out', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );

    capture.handlePointerDown(
      const PointerDownEvent(pointer: 1, position: Offset(100, 200)),
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 2, position: Offset(280, 200)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(150, 200)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 2, position: Offset(230, 200)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 1, position: Offset(150, 200)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 2, position: Offset(230, 200)),
    );
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(1));
    expect(interactions.single.data['gesture'], 'zoom_out');
  });

  test('pinch from nearby contacts still records zoom_in', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 1, position: Offset(190, 200)),
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 2, position: Offset(200, 200)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(150, 200)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 2, position: Offset(240, 200)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 1, position: Offset(150, 200)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 2, position: Offset(240, 200)),
    );
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(1));
    expect(interactions.single.data['gesture'], 'zoom_in');
    expect((interactions.single.data['payload'] as Map)['scale'], 9);
  });

  for (final liftedPointer in [1, 2]) {
    testWidgets('pinch survives replacement of pointer $liftedPointer', (
      tester,
    ) async {
      final harness = ReplayCoherenceHarness(
        profile: TugboatCaptureProfile.productionLean,
      );
      await harness.setUpWidgetBacked(tester);
      addTearDown(harness.dispose);
      harness.seedRouteState(route: '/pinch');
      final capture = InputCapture(
        controller: harness.controller,
        rootKey: harness.boundaryKey,
      );
      capture.handlePointerDown(
        const PointerDownEvent(pointer: 1, position: Offset(100, 200)),
      );
      capture.handlePointerDown(
        const PointerDownEvent(pointer: 2, position: Offset(200, 200)),
      );
      capture.handlePointerMove(
        const PointerMoveEvent(pointer: 2, position: Offset(250, 200)),
      );
      capture.handlePointerUp(
        PointerUpEvent(
          pointer: liftedPointer,
          position: Offset(liftedPointer == 1 ? 100 : 250, 200),
        ),
      );
      await harness.flushScheduler();
      expect(
        harness.controller.session!.ofType('interaction'),
        isEmpty,
        reason: 'A contact is still down.',
      );

      final remainingPointer = liftedPointer == 1 ? 2 : 1;
      final remainingPosition = Offset(liftedPointer == 1 ? 250 : 100, 200);
      capture.handlePointerDown(
        PointerDownEvent(
          pointer: 3,
          position: remainingPosition + const Offset(100, 0),
        ),
      );
      capture.handlePointerMove(
        PointerMoveEvent(
          pointer: 3,
          position: remainingPosition + const Offset(200, 0),
        ),
      );
      capture.handlePointerUp(
        PointerUpEvent(pointer: remainingPointer, position: remainingPosition),
      );
      capture.handlePointerUp(
        PointerUpEvent(
          pointer: 3,
          position: remainingPosition + const Offset(200, 0),
        ),
      );
      await harness.flushScheduler();

      final interactions = harness.controller.session!.ofType('interaction');
      expect(interactions, hasLength(1));
      expect(interactions.single.data['gesture'], 'zoom_in');
      final payload = interactions.single.data['payload'] as Map;
      expect(payload['pointerCount'], 2);
      expect(payload['scale'], closeTo(3, 0.001));
      final size = tester.getSize(find.byKey(harness.boundaryKey));
      final delta = payload['delta'] as Map;
      final end = payload['endPosition'] as Map;
      final continuedTravel = liftedPointer == 1 ? 50.0 : 0.0;
      expect(delta['xNorm'], closeTo(continuedTravel / size.width, 0.001));
      expect(delta['yNorm'], closeTo(0, 0.001));
      expect(
        end['xNorm'],
        closeTo((100 + continuedTravel) / size.width, 0.001),
      );
    });
  }

  for (final replaceContact in [false, true]) {
    testWidgets(
      'pan travel continues after primary lift, replace=$replaceContact',
      (tester) async {
        final harness = ReplayCoherenceHarness(
          profile: TugboatCaptureProfile.productionLean,
        );
        await harness.setUpWidgetBacked(tester);
        addTearDown(harness.dispose);
        harness.seedRouteState(route: '/pan');
        final capture = InputCapture(
          controller: harness.controller,
          rootKey: harness.boundaryKey,
        );
        capture.handlePointerDown(
          const PointerDownEvent(pointer: 1, position: Offset(100, 100)),
        );
        capture.handlePointerDown(
          const PointerDownEvent(pointer: 2, position: Offset(200, 100)),
        );
        capture.handlePointerMove(
          const PointerMoveEvent(pointer: 1, position: Offset(100, 140)),
        );
        capture.handlePointerMove(
          const PointerMoveEvent(pointer: 2, position: Offset(200, 140)),
        );
        capture.handlePointerUp(
          const PointerUpEvent(pointer: 1, position: Offset(100, 140)),
        );
        capture.handlePointerMove(
          const PointerMoveEvent(pointer: 2, position: Offset(200, 180)),
        );
        if (replaceContact) {
          // Contact membership changes must not add a coordinate jump.
          capture.handlePointerDown(
            const PointerDownEvent(pointer: 3, position: Offset(400, 180)),
          );
          capture.handlePointerMove(
            const PointerMoveEvent(pointer: 2, position: Offset(200, 200)),
          );
          capture.handlePointerMove(
            const PointerMoveEvent(pointer: 3, position: Offset(400, 200)),
          );
          capture.handlePointerUp(
            const PointerUpEvent(pointer: 2, position: Offset(200, 200)),
          );
          capture.handlePointerUp(
            const PointerUpEvent(pointer: 3, position: Offset(400, 220)),
          );
        } else {
          capture.handlePointerUp(
            const PointerUpEvent(pointer: 2, position: Offset(200, 220)),
          );
        }
        await harness.flushScheduler();

        final interactions = harness.controller.session!.ofType('interaction');
        expect(interactions, hasLength(1));
        expect(interactions.single.data['gesture'], 'pan');
        final payload = interactions.single.data['payload'] as Map;
        final size = tester.getSize(find.byKey(harness.boundaryKey));
        final delta = payload['delta'] as Map;
        final end = payload['endPosition'] as Map;
        expect(delta['xNorm'], closeTo(0, 0.001));
        expect(delta['yNorm'], closeTo(120 / size.height, 0.001));
        expect(end['xNorm'], closeTo(100 / size.width, 0.001));
        expect(end['yNorm'], closeTo(220 / size.height, 0.001));
      },
    );
  }

  test('stationary three-finger contact records three taps', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );
    for (var pointer = 1; pointer <= 3; pointer++) {
      capture.handlePointerDown(
        PointerDownEvent(
          pointer: pointer,
          position: Offset(80.0 * pointer, 200),
        ),
      );
    }
    for (var pointer = 1; pointer <= 3; pointer++) {
      capture.handlePointerUp(
        PointerUpEvent(pointer: pointer, position: Offset(80.0 * pointer, 200)),
      );
    }
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(3));
    expect(interactions.map((event) => event.data['gesture']).toSet(), {'tap'});
  });

  test('third contact sets the span before a pinch is classified', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );
    const starts = {
      1: Offset(100, 200),
      2: Offset(120, 200),
      3: Offset(300, 200),
    };
    for (final entry in starts.entries) {
      capture.handlePointerDown(
        PointerDownEvent(pointer: entry.key, position: entry.value),
      );
    }
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 3, position: Offset(350, 200)),
    );
    for (final entry in starts.entries) {
      capture.handlePointerUp(
        PointerUpEvent(
          pointer: entry.key,
          position: entry.key == 3 ? const Offset(350, 200) : entry.value,
        ),
      );
    }
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(1));
    expect(interactions.single.data['gesture'], 'zoom_in');
    final payload = interactions.single.data['payload'] as Map;
    expect(payload['pointerCount'], 3);
    expect(payload['scale'], closeTo(1.25, 0.001));
  });

  test('InputCapture two-finger translation records one pan', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );

    capture.handlePointerDown(
      const PointerDownEvent(pointer: 1, position: Offset(140, 160)),
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 2, position: Offset(220, 160)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(140, 210)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 2, position: Offset(220, 210)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 1, position: Offset(140, 210)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 2, position: Offset(220, 210)),
    );
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(1));
    expect(interactions.single.data['gesture'], 'pan');
  });

  test('InputCapture stationary two-finger contact records two taps', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );

    capture.handlePointerDown(
      const PointerDownEvent(pointer: 1, position: Offset(140, 200)),
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 2, position: Offset(220, 200)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 1, position: Offset(140, 200)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 2, position: Offset(220, 200)),
    );
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(2));
    expect(interactions.map((event) => event.data['gesture']).toSet(), {'tap'});
  });

  test('shared three-pointer translation past pan slop is swipe', () {
    expect(
      classifyMultiPointerGesture(
        pointerCount: 3,
        startSpan: 100,
        currentSpan: 100,
        startCentroid: const Offset(50, 50),
        currentCentroid: const Offset(50, 100),
      ),
      InteractionGesture.swipe,
    );
  });

  test('InputCapture three-finger translation records one swipe', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );

    capture.handlePointerDown(
      const PointerDownEvent(pointer: 1, position: Offset(120, 160)),
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 2, position: Offset(200, 160)),
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 3, position: Offset(280, 160)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(120, 220)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 2, position: Offset(200, 220)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 3, position: Offset(280, 220)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 1, position: Offset(120, 220)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 2, position: Offset(200, 220)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 3, position: Offset(280, 220)),
    );
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(1));
    expect(interactions.single.data['gesture'], 'swipe');
    final payload = Map<String, Object?>.from(
      interactions.single.data['payload']! as Map,
    );
    expect(payload['pointerCount'], 3);
  });

  test('stationary third finger keeps an established two-finger pan', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );

    capture.handlePointerDown(
      const PointerDownEvent(pointer: 1, position: Offset(120, 160)),
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 2, position: Offset(200, 160)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(120, 220)),
    );
    capture.handlePointerMove(
      const PointerMoveEvent(pointer: 2, position: Offset(200, 220)),
    );
    capture.handlePointerDown(
      const PointerDownEvent(pointer: 3, position: Offset(280, 220)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 3, position: Offset(280, 220)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 1, position: Offset(120, 220)),
    );
    capture.handlePointerUp(
      const PointerUpEvent(pointer: 2, position: Offset(200, 220)),
    );
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(1));
    expect(interactions.single.data['gesture'], 'pan');
    final payload = Map<String, Object?>.from(
      interactions.single.data['payload']! as Map,
    );
    expect(payload['pointerCount'], 2);
  });

  test('InputCapture trackpad pinch records zoom_in', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );

    capture.handlePanZoomStart(
      const PointerPanZoomStartEvent(pointer: 7, position: Offset(200, 200)),
    );
    capture.handlePanZoomUpdate(
      const PointerPanZoomUpdateEvent(
        pointer: 7,
        position: Offset(200, 200),
        scale: 1.35,
      ),
    );
    capture.handlePanZoomEnd(
      const PointerPanZoomEndEvent(pointer: 7, position: Offset(200, 200)),
    );
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(1));
    expect(interactions.single.data['gesture'], 'zoom_in');
    final payload = Map<String, Object?>.from(
      interactions.single.data['payload']! as Map,
    );
    expect(payload['scale'], 1.35);
  });

  test('primary end position ignores a secondary lift location', () {
    expect(
      primaryPointerEndPosition(
        primaryPointer: 1,
        pointerPositions: const {1: Offset(140, 210), 2: Offset(220, 210)},
        fallback: Offset(220, 210),
      ),
      const Offset(140, 210),
    );
  });

  testWidgets('trackpad pan records its travel instead of a stationary point', (
    tester,
  ) async {
    final harness = ReplayCoherenceHarness(
      profile: TugboatCaptureProfile.productionLean,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: harness.boundaryKey,
          child: const ColoredBox(color: Colors.blue),
        ),
      ),
    );
    await harness.setUp();
    addTearDown(harness.dispose);
    harness.seedRouteState(route: '/trackpad');
    final capture = InputCapture(
      controller: harness.controller,
      rootKey: harness.boundaryKey,
    );
    capture.handlePanZoomStart(
      const PointerPanZoomStartEvent(pointer: 7, position: Offset(200, 200)),
    );
    capture.handlePanZoomUpdate(
      const PointerPanZoomUpdateEvent(
        pointer: 7,
        position: Offset(200, 200),
        pan: Offset(60, 80),
      ),
    );
    capture.handlePanZoomEnd(
      const PointerPanZoomEndEvent(pointer: 7, position: Offset(200, 200)),
    );
    await harness.flushScheduler();

    final interactions = harness.controller.session!.ofType('interaction');
    expect(interactions, hasLength(1));
    expect(interactions.single.data['gesture'], 'pan');
    final delta = (interactions.single.data['payload'] as Map)['delta'] as Map;
    final size = tester.getSize(find.byKey(harness.boundaryKey));
    expect(delta['xNorm'], closeTo(60 / size.width, 0.001));
    expect(delta['yNorm'], closeTo(80 / size.height, 0.001));
  });

  test(
    'InputCapture secondary lift records one pan from the primary pointer',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      final capture = InputCapture(
        controller: harness.controller,
        rootKey: harness.boundaryKey,
      );

      capture.handlePointerDown(
        const PointerDownEvent(pointer: 1, position: Offset(140, 160)),
      );
      capture.handlePointerDown(
        const PointerDownEvent(pointer: 2, position: Offset(220, 160)),
      );
      capture.handlePointerMove(
        const PointerMoveEvent(pointer: 1, position: Offset(140, 210)),
      );
      capture.handlePointerMove(
        const PointerMoveEvent(pointer: 2, position: Offset(220, 210)),
      );
      capture.handlePointerUp(
        const PointerUpEvent(pointer: 2, position: Offset(220, 210)),
      );
      capture.handlePointerUp(
        const PointerUpEvent(pointer: 1, position: Offset(140, 210)),
      );
      await harness.flushScheduler();

      final interactions = harness.controller.session!.ofType('interaction');
      expect(interactions, hasLength(1));
      expect(interactions.single.data['gesture'], 'pan');
      final payload = Map<String, Object?>.from(
        interactions.single.data['payload']! as Map,
      );
      expect(payload['pointerCount'], 2);
    },
  );

  for (final primaryLifted in [false, true]) {
    test(
      'multi-pointer cancel clears contacts (primary lifted=$primaryLifted)',
      () async {
        final harness = ReplayCoherenceHarness();
        await harness.setUp();
        addTearDown(harness.dispose);
        final capture = InputCapture(
          controller: harness.controller,
          rootKey: harness.boundaryKey,
        );

        capture.handlePointerDown(
          const PointerDownEvent(pointer: 1, position: Offset(140, 160)),
        );
        capture.handlePointerDown(
          const PointerDownEvent(pointer: 2, position: Offset(220, 160)),
        );
        capture.handlePointerMove(
          const PointerMoveEvent(pointer: 1, position: Offset(140, 210)),
        );
        capture.handlePointerMove(
          const PointerMoveEvent(pointer: 2, position: Offset(220, 210)),
        );
        if (primaryLifted) {
          capture.handlePointerUp(
            const PointerUpEvent(pointer: 1, position: Offset(140, 210)),
          );
        }
        capture.handlePointerCancel(
          const PointerCancelEvent(pointer: 2, position: Offset(220, 210)),
        );
        capture.handlePointerMove(
          const PointerMoveEvent(pointer: 1, position: Offset(140, 240)),
        );
        capture.handlePointerDown(
          const PointerDownEvent(pointer: 3, position: Offset(200, 400)),
        );
        capture.handlePointerMove(
          const PointerMoveEvent(pointer: 3, position: Offset(200, 460)),
        );
        capture.handlePointerUp(
          const PointerUpEvent(pointer: 3, position: Offset(200, 460)),
        );
        await harness.flushScheduler();

        final interactions = harness.controller.session!.ofType('interaction');
        expect(interactions.map((event) => event.data['gesture']).toList(), [
          'cancelled',
          'swipe',
        ]);
      },
    );
  }

  group('widget capture', () {
    setUp(TugboatReplay.resetForTest);
    tearDown(TugboatReplay.resetForTest);

    for (final globalCapture in [true, false]) {
      for (final state in [
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
      ]) {
        testWidgets(
          'new swipe after $state without pointer cancel, global=$globalCapture',
          (tester) async {
            TugboatReplay.debugConfigureControllerForTest = (controller) {
              controller.debugExecuteCapture =
                  ({required trigger, required force}) async =>
                      controller.debugSeedFrame(trigger: trigger);
            };
            await tester.pumpWidget(
              MaterialApp(
                builder: (context, child) => TugboatReplay.wrapApp(
                  config: TugboatReplayConfig(
                    profile: TugboatCaptureProfile.productionLean,
                    enableGlobalPointerCapture: globalCapture,
                    settleDelay: Duration.zero,
                    interactionClaimWindow: Duration.zero,
                  ),
                  child: child!,
                ),
                home: const Scaffold(body: ColoredBox(color: Colors.blue)),
              ),
            );
            await tester.pump();
            final controller = TugboatReplay.controller!;
            final first = await tester.startGesture(
              const Offset(100, 100),
              pointer: 1,
            );
            final second = await tester.startGesture(
              const Offset(200, 100),
              pointer: 2,
            );
            await first.moveTo(const Offset(100, 140));
            await second.moveTo(const Offset(200, 140));

            // Do not send PointerCancel: lifecycle must clear capture's contacts.
            tester.binding.handleAppLifecycleStateChanged(state);
            await tester.pump();
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pump();
            final third = await tester.startGesture(
              const Offset(150, 300),
              pointer: 3,
            );
            await third.moveTo(const Offset(150, 380));
            await third.up();
            await first.up();
            await second.up();
            await tester.pump();
            await controller.drainPointerQueue();

            final gestures = controller.session!.events
                .where((event) => event.type == 'interaction')
                .map((event) => event.data['gesture']);
            // Lifecycle finalization retains the already classified pan.
            expect(gestures, ['pan', 'swipe']);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
      for (final gesture in ['zoom_in', 'zoom_out', 'pan']) {
        testWidgets('$gesture through global capture=$globalCapture', (
          tester,
        ) async {
          final transform = TransformationController();
          addTearDown(transform.dispose);
          TugboatReplay.debugConfigureControllerForTest = (controller) {
            controller.debugExecuteCapture =
                ({required trigger, required force}) async =>
                    controller.debugSeedFrame(trigger: trigger);
          };
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => TugboatReplay.wrapApp(
                config: TugboatReplayConfig(
                  profile: TugboatCaptureProfile.productionLean,
                  enableGlobalPointerCapture: globalCapture,
                  settleDelay: Duration.zero,
                  interactionClaimWindow: Duration.zero,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: InteractiveViewer(
                  transformationController: transform,
                  minScale: 0.1,
                  maxScale: 10,
                  constrained: false,
                  child: const SizedBox(
                    width: 1200,
                    height: 1200,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          final controller = TugboatReplay.controller!;
          expect(controller.session, isNotNull);

          final first = await tester.startGesture(
            const Offset(250, 250),
            pointer: 1,
          );
          final second = await tester.startGesture(
            const Offset(450, 250),
            pointer: 2,
          );
          for (var step = 1; step <= 8; step++) {
            final distance = step * 8.0;
            final delta = gesture == 'pan'
                ? Offset(0, -distance)
                : Offset(gesture == 'zoom_in' ? -distance : distance, 0);
            await first.moveTo(const Offset(250, 250) + delta);
            await second.moveTo(
              const Offset(450, 250) + (gesture == 'pan' ? delta : -delta),
            );
            await tester.pump(const Duration(milliseconds: 16));
          }
          await second.up();
          await tester.pump();
          expect(
            controller.session!.events.where((e) => e.type == 'interaction'),
            isEmpty,
          );
          await first.up();
          await tester.pump();
          await controller.drainPointerQueue();

          final interactions = controller.session!.events
              .where((event) => event.type == 'interaction')
              .toList();
          expect(interactions, hasLength(1));
          expect(interactions.single.data['gesture'], gesture);
          expect(
            (interactions.single.data['payload'] as Map)['pointerCount'],
            2,
          );
          final matrix = transform.value;
          if (gesture == 'zoom_in') {
            expect(matrix.getMaxScaleOnAxis(), greaterThan(1));
          } else if (gesture == 'zoom_out') {
            expect(matrix.getMaxScaleOnAxis(), lessThan(1));
          } else {
            expect(matrix.getTranslation().y, lessThan(0));
          }
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  });
}
