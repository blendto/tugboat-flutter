import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat_example/main.dart';

Future<void> _waitForTugboatEvents(WidgetTester tester) async {
  for (var attempt = 0; attempt < 12; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Map<String, Object?> _semanticAnnotation(TugboatEvent event) {
  final raw = event.data['semanticAnnotation'];
  return Map<String, Object?>.from(raw! as Map);
}

void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  testWidgets('demo app loads home screen', (tester) async {
    await tester.pumpWidget(const ReplayDemoApp());
    await tester.pump();
    expect(find.text('Tugboat Replay Demo'), findsOneWidget);
    expect(find.text('Explore every screen'), findsOneWidget);
    expect(find.text('Product catalog'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  });

  testWidgets(
    'generation count tap emits its semantic parameter label and value',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TugboatReplay.activate(
        activationRequestId: 'example-semantic-parameter-test',
        profile: TugboatCaptureProfile.productionLean,
      );
      await tester.pumpWidget(const ReplayDemoApp());
      await _waitForTugboatEvents(tester);

      await tester.tap(find.text('Profile & settings'));
      await tester.pumpAndSettle();
      await _waitForTugboatEvents(tester);

      await tester.tap(find.byKey(const Key('generation-count-3')));
      await _waitForTugboatEvents(tester);

      final tap = TugboatReplay.controller!.session!.events.lastWhere(
        (event) => event.type == 'tap',
      );
      final annotation = _semanticAnnotation(tap);

      expect(annotation['label'], {
        'kind': 'string',
        'value': 'Number of generations',
      });
      expect(annotation['value'], {'kind': 'string', 'value': '3'});
      expect(annotation['selected'], isFalse);
    },
  );
}
