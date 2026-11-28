import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// BLE-716: a scroll target carries `enabled: true` and native's confidence
// rule (medium for a named view or a list item, else low), as on Android.
const _config = TugboatReplayConfig(
  enabled: true,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: true,
  capturePixelRatio: 1.0,
);

Future<Map<String, Object?>> _scrollAnchor(
  WidgetTester tester, {
  required Widget Function(Widget list) wrap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _config, child: child!),
      home: Scaffold(
        body: wrap(
          ListView.builder(
            itemCount: 30,
            itemBuilder: (context, index) =>
                SizedBox(height: 80, child: Text('Item $index')),
          ),
        ),
      ),
    ),
  );
  final controller = TugboatReplay.controller!;
  controller.debugExecuteCapture = ({required trigger, required force}) async =>
      controller.debugSeedFrame(trigger: trigger);
  await settleTugboatCaptureWork(tester);

  final gesture = await tester.startGesture(const Offset(200, 300));
  await gesture.moveBy(const Offset(0, -150));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.up();
  await tester.pumpAndSettle();
  await settleTugboatCaptureWork(tester);

  final scroll = controller.session!.events.singleWhere(
    (e) => e.type == 'interaction' && e.data['gesture'] == 'scroll',
  );
  return scroll.targetAnchor!.toJson();
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('an unnamed scrollable is enabled with low confidence', (
    tester,
  ) async {
    final anchor = await _scrollAnchor(tester, wrap: (list) => list);
    expect(anchor['role'], 'scrollable');
    expect(anchor['enabled'], true);
    expect(anchor['fingerprintConfidence'], 'low');
  });

  testWidgets('a tagged scrollable has medium confidence', (tester) async {
    final anchor = await _scrollAnchor(
      tester,
      wrap: (list) => TugboatTag('feed', child: list),
    );
    expect(anchor['enabled'], true);
    expect(anchor['fingerprintConfidence'], 'medium');
  });
}
