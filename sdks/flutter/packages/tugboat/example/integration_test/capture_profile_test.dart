import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tugboat_example/main.dart';
import 'package:tugboat_example/profiling.dart';

/// Fixed interaction script for comparing screenshot backends on a device.
///
/// Run with `flutter drive --profile` (see README.md in this folder). Debug
/// timings are not meaningful.
///
/// A failing script step or a framework error report does not fail the run:
/// both are recorded in the summary (`scriptError`, `frameworkErrors`) so the
/// numbers collected up to that point are still reported.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  const rounds = int.fromEnvironment('TUGBOAT_PROFILE_ROUNDS', defaultValue: 3);

  testWidgets('capture backend profile', (tester) async {
    final profiler = CaptureProfiler.instance..start();
    await tester.pumpWidget(const ReplayDemoApp());
    await _idle(tester, 3000);
    profiler.reset();
    _frameworkErrors.clear();

    String? scriptError;
    try {
      await _script(tester, rounds);
    } catch (error) {
      scriptError = '$error'.replaceAll(RegExp(r'\s+'), ' ');
      if (scriptError.length > 240) {
        scriptError = '${scriptError.substring(0, 237)}...';
      }
    }

    await _idle(tester, 2000);
    final summary = {
      ...profiler.summary(label: profileBackend.name),
      'rounds': rounds,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'scriptError': ?scriptError,
      'frameworkErrors': {
        'count': _frameworkErrors.length,
        if (_frameworkErrors.isNotEmpty) 'first': _frameworkErrors.first,
      },
    };
    profiler.printSummary(label: profileBackend.name);
    binding.reportData = {'summary': summary};
  }, timeout: const Timeout(Duration(minutes: 15)));
}

/// Framework error reports (layout overflows, debug assertions) seen while
/// the script ran. Collected instead of failing the benchmark.
final _frameworkErrors = <String>[];

Future<void> _script(WidgetTester tester, int rounds) async {
  {
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
  }
}

Future<void> _idle(WidgetTester tester, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
    final error = tester.takeException();
    if (error != null && _frameworkErrors.length < 20) {
      final text = '$error'.replaceAll(RegExp(r'\s+'), ' ');
      _frameworkErrors.add(
        text.length > 200 ? '${text.substring(0, 197)}...' : text,
      );
    }
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
