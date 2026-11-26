import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import '../helpers/replay_coherence_harness.dart';

/// Presses one pointer from [down] to [up], held for [heldMs] on the
/// controller clock, and returns the single published interaction.
Future<TugboatEvent> _press(
  ReplayCoherenceHarness harness, {
  required int heldMs,
  Offset down = const Offset(10, 10),
  Offset? up,
  bool swipe = false,
}) async {
  var nowMs = 1000;
  harness.controller.debugElapsedMs = () => nowMs;
  harness.controller.recordPointerDown(down);
  if (swipe) harness.controller.markPendingTapAsSwipe(0);
  nowMs += heldMs;
  harness.controller.recordPointerUp(up ?? down);
  await harness.flushScheduler();
  return harness.controller.session!.events
      .where((event) => event.type == 'interaction')
      .single;
}

Map<String, Object?> _payload(TugboatEvent interaction) =>
    Map<String, Object?>.from(interaction.data['payload'] as Map? ?? {});

Future<ReplayCoherenceHarness> _harness({required bool capture}) async {
  final harness = ReplayCoherenceHarness(capturePressDuration: capture);
  await harness.setUp();
  addTearDown(harness.dispose);
  return harness;
}

void main() {
  group('Tap press duration (BLE-567)', () {
    test('is off by default', () async {
      expect(const TugboatReplayConfig().capturePressDuration, isFalse);
      final harness = await _harness(capture: false);

      final tap = await _press(harness, heldMs: 1500);

      expect(tap.data['gesture'], 'tap');
      expect(_payload(tap).containsKey('pressDurationMs'), isFalse);
    });

    test('a short tap carries its press duration', () async {
      final harness = await _harness(capture: true);

      final tap = await _press(harness, heldMs: 80);

      expect(tap.data['gesture'], 'tap');
      expect(_payload(tap)['pressDurationMs'], 80);
    });

    test('a long press stays a tap and carries its press duration', () async {
      final harness = await _harness(capture: true);

      final tap = await _press(harness, heldMs: 1500);

      expect(tap.data['gesture'], 'tap');
      expect(_payload(tap)['pressDurationMs'], 1500);
    });

    test(
      'a press that moves under the touch slop keeps its duration',
      () async {
        final harness = await _harness(capture: true);

        final tap = await _press(
          harness,
          heldMs: 600,
          up: const Offset(10 + kTouchSlop - 1, 10),
        );

        expect(tap.data['gesture'], 'tap');
        expect(_payload(tap)['pressDurationMs'], 600);
      },
    );

    test('a swipe never carries a press duration', () async {
      final harness = await _harness(capture: true);

      final swipe = await _press(
        harness,
        heldMs: 400,
        down: const Offset(10, 100),
        up: const Offset(10, 40),
        swipe: true,
      );

      expect(swipe.data['gesture'], isNot('tap'));
      expect(_payload(swipe).containsKey('pressDurationMs'), isFalse);
    });
  });
}
