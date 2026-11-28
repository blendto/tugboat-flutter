import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// BLE-699: a tap target's role, enabled and actions describe the tapped
// element only, as on native Android. A scrollable parent adds no `scroll`.

const _config = TugboatReplayConfig(
  enabled: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

Future<Map<String, Object?>> _tapAnchor(
  WidgetTester tester,
  Finder at, {
  Widget Function(Widget list)? wrap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _config, child: child!),
      home: Scaffold(
        body: (wrap ?? (list) => list)(
          ListView(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Enabled')),
              const FilledButton(onPressed: null, child: Text('Disabled')),
              const TextField(key: Key('field')),
              const Text('Plain'),
            ],
          ),
        ),
      ),
    ),
  );
  await waitForTugboatCaptureWork(tester);
  await tester.tap(at, warnIfMissed: false);
  await tester.pump();
  for (var i = 0; i < 200 && !_hasTap(); i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await waitForTugboatCaptureWork(tester);
  final tap = TugboatReplay.controller!.session!.events.lastWhere(
    (e) => e.type == 'interaction' && e.data['gesture'] == 'tap',
  );
  return tap.targetAnchor!.toJson();
}

bool _hasTap() => [
  for (final e
      in TugboatReplay.controller?.session?.events ?? const <TugboatEvent>[])
    e,
].any((e) => e.type == 'interaction' && e.data['gesture'] == 'tap');

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a button in a list reports only its own tap', (tester) async {
    final anchor = await _tapAnchor(tester, find.text('Enabled'));
    expect(anchor['role'], 'button');
    expect(anchor['enabled'], true);
    expect(anchor['actions'], ['tap']);
  });

  testWidgets('a disabled button in a list reports no actions', (tester) async {
    final anchor = await _tapAnchor(tester, find.text('Disabled'));
    expect(anchor['role'], 'button');
    expect(anchor['enabled'], false);
    expect(anchor.containsKey('actions'), isFalse);
  });

  testWidgets('a tap on plain list content still reports the scrollable', (
    tester,
  ) async {
    final anchor = await _tapAnchor(tester, find.text('Plain'));
    expect(anchor['role'], 'scrollable');
    expect(anchor['enabled'], true); // BLE-716
    expect(anchor['actions'], ['scroll']);
  });

  testWidgets('a list under a tappable ancestor keeps its own role', (
    tester,
  ) async {
    final anchor = await _tapAnchor(
      tester,
      find.text('Plain'),
      wrap: (list) => GestureDetector(onTap: () {}, child: list),
    );
    expect(anchor['role'], 'scrollable');
    expect(anchor['actions'], ['scroll']);
  });

  testWidgets('a text field in a list reports only input', (tester) async {
    final anchor = await _tapAnchor(tester, find.byKey(const Key('field')));
    expect(anchor['role'], 'textField');
    expect(anchor['enabled'], true);
    expect(anchor['actions'], ['input']);
  });
}
