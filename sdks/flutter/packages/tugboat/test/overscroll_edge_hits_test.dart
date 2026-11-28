import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// BLE-714: overscrollCount counts edge hits (as on Android), not the
// overscroll updates a drag sends. A drag held at an edge is 1; leaving the
// edge and reaching it again is 2.
const _config = TugboatReplayConfig(
  enabled: true,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: true,
  capturePixelRatio: 1.0,
);

Future<Object?> _overscrollCountOfDrag(
  WidgetTester tester,
  ScrollPhysics physics,
  List<double> moves,
) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _config, child: child!),
      home: Scaffold(
        body: ListView.builder(
          physics: physics,
          itemCount: 30,
          itemBuilder: (context, index) =>
              SizedBox(height: 80, child: Text('Edge item $index')),
        ),
      ),
    ),
  );
  final controller = TugboatReplay.controller!;
  controller.debugExecuteCapture = ({required trigger, required force}) async =>
      controller.debugSeedFrame(trigger: trigger);
  await settleTugboatCaptureWork(tester);

  final gesture = await tester.startGesture(const Offset(200, 200));
  for (final dy in moves) {
    await gesture.moveBy(Offset(0, dy));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
  await settleTugboatCaptureWork(tester);

  final scrolls = controller.session!.events.where(
    (e) => e.type == 'interaction' && e.data['gesture'] == 'scroll',
  );
  expect(scrolls, hasLength(1));
  return (scrolls.single.data['payload']! as Map)['overscrollCount'];
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  // Pull down at the top (past the start edge) in several updates.
  const heldAtEdge = [60.0, 20.0, 20.0, 20.0];
  // Pull, push back inside the extents, pull again.
  const leaveAndReturn = [60.0, 20.0, -200.0, 300.0, 20.0];

  for (final physics in <String, ScrollPhysics>{
    'clamping': const ClampingScrollPhysics(),
    'bouncing': const BouncingScrollPhysics(),
  }.entries) {
    testWidgets('${physics.key}: a drag held at an edge is one edge hit', (
      tester,
    ) async {
      expect(
        await _overscrollCountOfDrag(tester, physics.value, heldAtEdge),
        1,
      );
    });

    testWidgets(
      '${physics.key}: leaving the edge and reaching it again is two',
      (tester) async {
        expect(
          await _overscrollCountOfDrag(tester, physics.value, leaveAndReturn),
          2,
        );
      },
    );
  }
}
