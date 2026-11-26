import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tugboat_example/main.dart';
import 'package:tugboat_example/profiling.dart';

/// Fixed interaction script for comparing screenshot backends on a device.
///
/// Run with `flutter drive --profile` (see README.md in this folder). Debug
/// timings are not meaningful.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  const rounds = int.fromEnvironment('TUGBOAT_PROFILE_ROUNDS', defaultValue: 3);

  testWidgets('capture backend profile', (tester) async {
    final profiler = CaptureProfiler.instance..start();
    await tester.pumpWidget(const ReplayDemoApp());
    await _idle(tester, 3000);
    profiler.reset();

    for (var round = 0; round < rounds; round++) {
      await _openFromHome(tester, 'Long browse feed');
      for (var i = 0; i < 4; i++) {
        await _fling(tester, const Offset(0, -900));
      }
      for (var i = 0; i < 4; i++) {
        await _fling(tester, const Offset(0, 900));
      }
      await _tapTooltip(tester, 'Expand all');
      await _fling(tester, const Offset(0, -1200));
      await _tapTooltip(tester, 'Collapse all');
      await _back(tester);

      await _openFromHome(tester, 'Product catalog');
      await _fling(tester, const Offset(0, -900));
      await _fling(tester, const Offset(0, 900));
      await _back(tester);

      await _openFromHome(tester, 'Scroll playground');
      await _fling(tester, const Offset(0, -900));
      await _fling(tester, const Offset(0, 900));
      await _back(tester);

      await _openFromHome(tester, 'Native privacy fixture');
      await _back(tester);
    }

    await _idle(tester, 2000);
    final summary = profiler.summary(label: profileBackend.name);
    profiler.printSummary(label: profileBackend.name);
    binding.reportData = {'summary': summary};
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Future<void> _idle(WidgetTester tester, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _openFromHome(WidgetTester tester, String title) async {
  final tile = find.text(title);
  await tester.scrollUntilVisible(
    tile,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await _idle(tester, 600);
  await tester.tap(tile);
  await _idle(tester, 1500);
}

Future<void> _fling(WidgetTester tester, Offset offset) async {
  await tester.fling(find.byType(Scrollable).last, offset, 2500);
  await _idle(tester, 1200);
}

Future<void> _tapTooltip(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await _idle(tester, 1200);
}

Future<void> _back(WidgetTester tester) async {
  await tester.pageBack();
  await _idle(tester, 1500);
}
