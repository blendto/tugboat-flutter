import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('InputCapture multi-pointer cancel clears leftover pointers', () async {
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
    capture.handlePointerCancel(
      const PointerCancelEvent(pointer: 2, position: Offset(220, 210)),
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
  });
}
