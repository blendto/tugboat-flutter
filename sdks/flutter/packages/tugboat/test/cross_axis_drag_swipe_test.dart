import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// BLE-717: like Android, a drag that moved no scrollable and hit no edge (a
// sideways swipe over a vertical list) is a swipe, not a scroll.
const _config = TugboatReplayConfig(
  enabled: true,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: true,
  capturePixelRatio: 1.0,
);

Future<Map<String, Object?>> _drag(
  WidgetTester tester,
  List<Offset> moves,
) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _config, child: child!),
      home: Scaffold(
        body: ListView.builder(
          itemCount: 30,
          itemBuilder: (context, index) =>
              SizedBox(height: 80, child: Text('Item $index')),
        ),
      ),
    ),
  );
  final controller = TugboatReplay.controller!;
  controller.debugExecuteCapture = ({required trigger, required force}) async =>
      controller.debugSeedFrame(trigger: trigger);
  await settleTugboatCaptureWork(tester);

  final gesture = await tester.startGesture(const Offset(200, 200));
  for (final move in moves) {
    await gesture.moveBy(move);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
  await settleTugboatCaptureWork(tester);

  final drags = controller.session!.events.where(
    (e) =>
        e.type == 'interaction' &&
        (e.data['gesture'] == 'scroll' || e.data['gesture'] == 'swipe'),
  );
  expect(drags, hasLength(1));
  return drags.single.data;
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a sideways drag over a vertical list is a swipe', (
    tester,
  ) async {
    // Net horizontal, with a vertical wobble that starts and ends the scroll
    // at offset 0 (the real-device shape).
    final data = await _drag(tester, const [Offset(60, -25), Offset(100, 25)]);
    expect(data['gesture'], 'swipe');
    final payload = data['payload']! as Map;
    expect(payload.keys, containsAll(['delta', 'endPosition', 'position']));
    expect(payload.keys, isNot(contains('startOffset')));
    expect(payload.keys, isNot(contains('endOffset')));
    expect(payload.keys, isNot(contains('overscrollCount')));
  });

  testWidgets('a vertical drag that moves the list is still a scroll', (
    tester,
  ) async {
    final data = await _drag(tester, const [Offset(0, -60), Offset(0, -60)]);
    expect(data['gesture'], 'scroll');
    final payload = data['payload']! as Map;
    expect(payload['startOffset'], 0.0);
    expect(payload['endOffset'], greaterThan(0));
  });

  testWidgets('a vertical drag at the edge is still a scroll with overscroll', (
    tester,
  ) async {
    final data = await _drag(tester, const [Offset(0, 60), Offset(0, 20)]);
    expect(data['gesture'], 'scroll');
    expect((data['payload']! as Map)['overscrollCount'], 1);
  });
}
