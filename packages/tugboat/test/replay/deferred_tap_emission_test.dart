import 'package:flutter_test/flutter_test.dart';

import '../helpers/replay_coherence_harness.dart';

void main() {
  test('pointer-down buffers tap until pointer-up', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(20, 30));
    expect(harness.controller.session!.ofType('tap'), isEmpty);

    harness.controller.recordPointerUp(const Offset(20, 30));
    final tap = harness.controller.session!.ofType('tap').single;
    expect(tap.data['x'], 20.0);
    expect(tap.data['y'], 30.0);
    expect(tap.data['captureCoordinate'], isA<Map>());
  });

  test(
    'swipe emits without phantom tap and carries startCaptureCoordinate',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(10, 100));
      harness.controller.markPendingTapAsSwipe(0);
      harness.controller.recordPointerUp(const Offset(10, 40));

      expect(harness.controller.session!.ofType('tap'), isEmpty);
      final swipe = harness.controller.session!.ofType('swipe').single;
      expect(swipe.relatedEventId, isNull);
      expect(swipe.data['startCaptureCoordinate'], isA<Map>());
      final start = Map<String, Object?>.from(
        swipe.data['startCaptureCoordinate']! as Map,
      );
      expect(
        start.containsKey('unavailableReason') || start['sourceSpace'] != null,
        isTrue,
      );
    },
  );

  test('cancel drops buffered tap', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(4, 4));
    harness.controller.recordPointerCancel(const Offset(4, 4));

    expect(harness.controller.session!.ofType('tap'), isEmpty);
    expect(harness.controller.session!.ofType('pointer_cancel'), hasLength(1));
  });

  test(
    'claimed-then-swiped tap still emits so causeEventId resolves',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(8, 8));
      await harness.controller.route('route_push', harness.route('/claimed'));
      await harness.pumpMicrotasks();

      final tap = harness.controller.session!.ofType('tap').single;
      harness.controller.markPendingTapAsSwipe(0);
      harness.controller.recordPointerUp(const Offset(8, 80));

      expect(harness.controller.session!.ofType('tap'), hasLength(1));
      final swipe = harness.controller.session!.ofType('swipe').single;
      expect(swipe.relatedEventId, tap.id);
      expect(swipe.data['startCaptureCoordinate'], isA<Map>());
    },
  );
}
