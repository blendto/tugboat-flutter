// Times the work the SDK does when a tap lands, on a deep, a wide and a mixed
// screen, and asserts on the median of repeated taps. Each tap goes through
// the controller (`recordPointerDown`, then `recordPointerUp`) under the
// default capture config and under scene inventory capture. A frame is forced
// before every tap so the resolver's per-frame token map cache is cold and the
// timed pair has to walk the tree, as a tap on a fresh frame does.
//
// This is a local regression guard that runs with the package test suite
// (`melos run test`, `flutter test -j 1`). CI does not gate on it. The budgets
// are a regression guard, not a performance promise: each one sits well above
// what this test measured on a shared Linux host, so noise does not trip it
// but an order-of-magnitude regression does. They say nothing about what a
// device will do.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

const _route = '/benchmark';

const _defaultConfig = TugboatReplayConfig(
  enabled: true,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1,
);

const _inventoryConfig = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  emitCaptureDiagnostics: true,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1,
);

/// Median tap budgets in microseconds, per screen and capture mode. Each is
/// about five times the highest median seen over repeated runs on a shared,
/// sometimes busy, Linux host.
class _Budgets {
  const _Budgets({required this.defaultMode, required this.inventoryMode});

  final int defaultMode;
  final int inventoryMode;
}

const _deepBudgets = _Budgets(defaultMode: 350000, inventoryMode: 360000);
const _wideBudgets = _Budgets(defaultMode: 3350000, inventoryMode: 6200000);
const _mixedBudgets = _Budgets(defaultMode: 890000, inventoryMode: 930000);

class _Screen {
  const _Screen({
    required this.name,
    required this.build,
    required this.tapTarget,
    required this.budgets,
    this.expectedRows,
  });

  final String name;
  final Widget Function() build;
  final Finder tapTarget;
  final _Budgets budgets;

  /// How many rows must really be mounted, so a lazy list cannot quietly
  /// shrink the tree being timed.
  final int? expectedRows;
}

const _deepLevels = 50;
const _wideRows = 200;

/// About [_deepLevels] nested widgets with a button at the bottom.
Widget _deepTree() {
  Widget node = ElevatedButton(onPressed: () {}, child: const Text('Deep'));
  for (var level = 0; level < _deepLevels; level++) {
    node = level.isEven
        ? Padding(padding: const EdgeInsets.all(0.5), child: node)
        : DecoratedBox(
            decoration: const BoxDecoration(color: Colors.transparent),
            child: node,
          );
  }
  return Scaffold(body: Center(child: node));
}

/// About [_wideRows] sibling rows, all mounted.
Widget _wideTree() => Scaffold(
  body: SingleChildScrollView(
    child: Column(
      children: [
        for (var i = 0; i < _wideRows; i++)
          ListTile(
            key: ValueKey('row-$i'),
            title: Text('Row $i'),
            onTap: () {},
          ),
      ],
    ),
  ),
);

/// App bar, a summary card, a mixed list, a bottom bar and a floating button.
Widget _mixedScreen() => Scaffold(
  appBar: AppBar(
    title: const Text('Account'),
    actions: [IconButton(icon: const Icon(Icons.search), onPressed: () {})],
  ),
  body: ListView(
    children: [
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Plan summary and renewal date'),
        ),
      ),
      for (var i = 0; i < 12; i++)
        ListTile(
          leading: const Icon(Icons.person),
          title: Text('Item $i'),
          subtitle: Text('Detail $i'),
          trailing: i.isEven ? Switch(value: true, onChanged: (_) {}) : null,
          onTap: () {},
        ),
      const Padding(
        padding: EdgeInsets.all(16),
        child: TextField(decoration: InputDecoration(labelText: 'Notes')),
      ),
      CheckboxListTile(
        value: false,
        onChanged: (_) {},
        title: const Text('Email me'),
      ),
    ],
  ),
  floatingActionButton: FloatingActionButton(
    onPressed: () {},
    child: const Icon(Icons.add),
  ),
  bottomNavigationBar: BottomNavigationBar(
    items: const [
      BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
      BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
    ],
  ),
);

final _screens = <_Screen>[
  _Screen(
    name: 'deep tree (50 nested widgets)',
    build: _deepTree,
    tapTarget: find.text('Deep'),
    budgets: _deepBudgets,
  ),
  _Screen(
    name: 'wide tree (200 sibling rows)',
    build: _wideTree,
    tapTarget: find.text('Row 2'),
    budgets: _wideBudgets,
    expectedRows: _wideRows,
  ),
  _Screen(
    name: 'mixed screen',
    build: _mixedScreen,
    tapTarget: find.text('Item 1'),
    budgets: _mixedBudgets,
  ),
];

const _warmUpTaps = 1;
const _measuredTaps = 5;

Future<TugboatReplayController> _mountController(
  WidgetTester tester,
  Widget child,
  TugboatReplayConfig config,
) async {
  TugboatReplay.debugConfigureControllerForTest = (controller) {
    controller.debugExecuteCapture =
        ({required trigger, required force}) async =>
            controller.debugSeedFrame(trigger: trigger);
  };
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, appChild) =>
          TugboatReplay.wrapApp(config: config, child: appChild!),
      home: child,
    ),
  );
  await tester.pump();
  await tester.pump();
  final controller = TugboatReplay.controller;
  expect(controller, isNotNull);
  expect(controller!.session, isNotNull);
  controller.debugSetCurrentRoute(_route);
  return controller;
}

Future<void> _settle(
  WidgetTester tester,
  TugboatReplayController controller,
) async {
  await controller.drainPointerQueue();
  await tester.pump(const Duration(milliseconds: 1));
  await controller.drainPointerQueue();
}

class _TapTiming {
  const _TapTiming(this.downMicros, this.upMicros, {this.sdkBuildMicros});

  final int downMicros;
  final int upMicros;

  /// The SDK's own pre-tap `buildMicros`, where the path reports one.
  final int? sdkBuildMicros;

  int get totalMicros => downMicros + upMicros;
}

List<TugboatEvent> _interactions(TugboatReplayController controller) =>
    controller.session!.events
        .where((event) => event.type == 'interaction')
        .toList();

/// The SDK's own pre-tap `buildMicros` from the newest diagnostic, or null
/// when the capture mode does not emit one.
int? _reportedBuildMicros(TugboatReplayController controller) {
  final diagnostics = controller.session!.events
      .where((event) => event.type == 'exploration_pre_tap_diagnostic')
      .toList();
  if (diagnostics.isEmpty) return null;
  expect(diagnostics.last.data['outcome'], 'captured');
  return diagnostics.last.data['buildMicros'] as int;
}

/// One controller tap, timed across the two synchronous SDK calls only.
///
/// A bare `pump()` draws no frame unless one is scheduled, so the resolver's
/// post-frame cache invalidation would never run. Scheduling one first makes
/// the token map cache cold for the timed pair.
Future<_TapTiming> _controllerTap(
  WidgetTester tester,
  TugboatReplayController controller,
  Offset position,
) async {
  tester.binding.scheduleFrame();
  await tester.pump();
  final buildsBefore = controller.debugAnchorTokenMapBuildCount;
  final interactionsBefore = _interactions(controller).length;
  final stopwatch = Stopwatch()..start();
  controller.recordPointerDown(position);
  final downMicros = stopwatch.elapsedMicroseconds;
  controller.recordPointerUp(position);
  final totalMicros = stopwatch.elapsedMicroseconds;
  stopwatch.stop();
  expect(
    controller.debugAnchorTokenMapBuildCount,
    greaterThan(buildsBefore),
    reason: 'a timed tap must walk the tree, not reuse a cached token map',
  );
  await _settle(tester, controller);
  final interactions = _interactions(controller);
  expect(interactions.length, interactionsBefore + 1);
  expect(interactions.last.data['targetFingerprint'], isNotEmpty);
  return _TapTiming(
    downMicros,
    totalMicros - downMicros,
    sdkBuildMicros: _reportedBuildMicros(controller),
  );
}

int _percentile(List<int> values, double fraction) {
  final sorted = [...values]..sort();
  return sorted[((sorted.length - 1) * fraction).round()];
}

String _ms(int micros) => (micros / 1000).toStringAsFixed(3);

void _report(String label, List<_TapTiming> timings) {
  final totals = [for (final t in timings) t.totalMicros];
  final downs = [for (final t in timings) t.downMicros];
  final ups = [for (final t in timings) t.upMicros];
  final sdkBuilds = [
    for (final t in timings)
      if (t.sdkBuildMicros != null) t.sdkBuildMicros!,
  ];
  final line = StringBuffer(
    'tap benchmark [$label] n=${timings.length} '
    'median=${_ms(_percentile(totals, 0.5))}ms '
    'p95=${_ms(_percentile(totals, 0.95))}ms '
    'down.median=${_ms(_percentile(downs, 0.5))}ms '
    'up.median=${_ms(_percentile(ups, 0.5))}ms',
  );
  if (sdkBuilds.isNotEmpty) {
    line.write(' sdkBuild.median=${_ms(_percentile(sdkBuilds, 0.5))}ms');
  }
  // ignore: avoid_print
  print(line);
}

Future<void> _runCase(
  WidgetTester tester,
  _Screen screen,
  TugboatReplayConfig config, {
  required String mode,
  required int budgetMicros,
}) async {
  final controller = await _mountController(tester, screen.build(), config);
  final rows = screen.expectedRows;
  if (rows != null) expect(find.byType(ListTile).evaluate().length, rows);
  final position = tester.getCenter(screen.tapTarget);

  final timings = <_TapTiming>[];
  for (var i = 0; i < _warmUpTaps + _measuredTaps; i++) {
    final timing = await _controllerTap(tester, controller, position);
    if (i >= _warmUpTaps) timings.add(timing);
  }
  final label = '${screen.name}, $mode';
  _report(label, timings);
  final median = _percentile([for (final t in timings) t.totalMicros], 0.5);
  expect(
    median,
    lessThan(budgetMicros),
    reason:
        '$label: median tap ${_ms(median)}ms exceeds the '
        '${_ms(budgetMicros)}ms regression budget',
  );
}

void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  for (final screen in _screens) {
    testWidgets('default capture tap stays within budget: ${screen.name}', (
      tester,
    ) async {
      await _runCase(
        tester,
        screen,
        _defaultConfig,
        mode: 'default capture',
        budgetMicros: screen.budgets.defaultMode,
      );
    });

    testWidgets('scene inventory tap stays within budget: ${screen.name}', (
      tester,
    ) async {
      await _runCase(
        tester,
        screen,
        _inventoryConfig,
        mode: 'scene inventory',
        budgetMicros: screen.budgets.inventoryMode,
      );
    });
  }
}
