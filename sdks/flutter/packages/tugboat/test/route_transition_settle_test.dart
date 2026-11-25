import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// The route capture waits for the route's deadline (its transition duration
// plus `settleDelay`) and then for every animation of the change to stop,
// plus two quiet frames, so the covered or departing page has gone offstage
// before the frame and inventory are taken (BLE-577). These tests pin that
// for a push, a pop, a pop whose reverse duration differs from the forward
// duration, a change that interrupts a running transition, and routes with
// no animation. Most record, at the moment each route capture executes, the
// fake time and what is still on stage, through `debugExecuteCapture`. That
// hook skips the fresh-paint wait of a real capture, so the route with no
// animation and no settle delay is checked on the real capture path instead,
// by its route inventory.

/// The settle delay of the test being run. Each case runs with a non-zero
/// delay and with none, where nothing but the frame wait keeps the capture
/// behind a transition that lags its duration.
var _settle = Duration.zero;

TugboatReplayConfig get _config => TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: _settle,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

/// What was true when one route capture executed.
class _RouteCaptureSnapshot {
  _RouteCaptureSnapshot({
    required this.elapsed,
    required this.onstage,
    required this.animating,
  });

  /// Fake time since the navigation under test.
  final Duration elapsed;

  /// Page labels found on stage.
  final Set<String> onstage;

  /// Labels of tracked routes whose animation was still running.
  final Set<String> animating;

  @override
  String toString() =>
      '_RouteCaptureSnapshot(elapsed: $elapsed, onstage: $onstage, '
      'animating: $animating)';
}

class _Harness {
  _Harness(this.tester);

  final WidgetTester tester;
  final navigatorKey = GlobalKey<NavigatorState>();
  final snapshots = <_RouteCaptureSnapshot>[];
  final routes = <String, Route<dynamic>>{};
  DateTime? _start;

  static const pages = ['Home page', 'First page', 'Second page'];

  Future<void> mount({Route<void> Function()? home}) async {
    TugboatReplay.debugConfigureControllerForTest = (controller) {
      controller.debugExecuteCapture =
          ({required trigger, required force}) async {
            if (trigger == TugboatFrameTrigger.route && _start != null) {
              snapshots.add(_snapshot());
            }
            return controller.debugSeedFrame(trigger: trigger);
          };
    };
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _config, child: child!),
        onGenerateRoute: (_) => null,
        onGenerateInitialRoutes: (_) {
          final route = home?.call() ?? pageRoute('Home page');
          routes['Home page'] = route;
          return [route];
        },
      ),
    );
    await waitForTugboatCaptureWork(tester);
  }

  _RouteCaptureSnapshot _snapshot() => _RouteCaptureSnapshot(
    elapsed: tester.binding.clock.now().difference(_start!),
    onstage: {
      for (final page in pages)
        if (find.text(page).evaluate().isNotEmpty) page,
    },
    animating: {
      for (final entry in routes.entries)
        if (entry.value is TransitionRoute<dynamic> &&
            ((entry.value as TransitionRoute<dynamic>).animation?.isAnimating ??
                false))
          entry.key,
    },
  );

  /// Starts the fake-time clock for [snapshots] at the next navigation.
  void markStart() {
    snapshots.clear();
    _start = tester.binding.clock.now();
  }

  NavigatorState get navigator => navigatorKey.currentState!;

  void push(String label, Route<void> route) {
    routes[label] = route;
    navigator.push(route);
  }

  /// Pumps 16 ms frames for [duration], as a device would.
  Future<void> frames(Duration duration) async {
    final end = tester.binding.clock.now().add(duration);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  List<TugboatEvent> routeChanges() => [
    for (final event in TugboatReplay.controller!.session!.events)
      if (event.type == 'route_change') event,
  ];

  List<Map<String, Object?>> routeInventories() => [
    for (final event in TugboatReplay.controller!.session!.events)
      if (event.type == 'scene_inventory' && event.data['trigger'] == 'route')
        event.data,
  ];
}

/// A page with one control, so its scene inventory is not empty.
Widget _page(String label) => Scaffold(
  body: Center(
    child: FilledButton(onPressed: () {}, child: Text(label)),
  ),
);

PageRouteBuilder<void> pageRoute(
  String label, {
  Duration forward = const Duration(milliseconds: 300),
  Duration? reverse,
}) => PageRouteBuilder<void>(
  settings: RouteSettings(name: '/${label.split(' ').first.toLowerCase()}'),
  transitionDuration: forward,
  reverseTransitionDuration: reverse ?? forward,
  pageBuilder: (_, _, _) => _page(label),
  transitionsBuilder: (_, animation, _, child) =>
      FadeTransition(opacity: animation, child: child),
);

/// An opaque route that is not a [TransitionRoute]: it has no animation.
class _InstantRoute extends OverlayRoute<void> {
  _InstantRoute(this.label)
    : super(
        settings: RouteSettings(
          name: '/${label.split(' ').first.toLowerCase()}',
        ),
      );

  final String label;

  @override
  Iterable<OverlayEntry> createOverlayEntries() => [
    OverlayEntry(
      opaque: true,
      maintainState: true,
      builder: (_) => _page(label),
    ),
  ];
}

void _expectSettled(
  _RouteCaptureSnapshot snapshot, {
  required String visible,
  required Duration notBefore,
}) {
  expect(
    snapshot.elapsed,
    greaterThanOrEqualTo(notBefore),
    reason: 'captured before transitionDuration + settleDelay: $snapshot',
  );
  expect(
    snapshot.animating,
    isEmpty,
    reason: 'captured while a route animation ran: $snapshot',
  );
  expect(snapshot.onstage, {
    visible,
  }, reason: 'captured while another page was on stage: $snapshot');
}

void main() {
  for (final settle in const [Duration(milliseconds: 200), Duration.zero]) {
    group('settleDelay ${settle.inMilliseconds} ms', () {
      setUp(() => _settle = settle);
      _cases();
    });
  }
  group('settleDelay 200 ms', () {
    setUp(() => _settle = const Duration(milliseconds: 200));
    _instantCases();
  });
  group('settleDelay 0 ms, real capture path', () {
    setUp(() => _settle = Duration.zero);
    _realPathCases();
  });
}

void _cases() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('push: captured after the transition and the covered page '
      'goes offstage', (tester) async {
    final h = _Harness(tester);
    await h.mount();

    h.markStart();
    h.push('First page', pageRoute('First page'));
    await h.frames(const Duration(seconds: 2));
    await waitForTugboatCaptureWork(tester);

    expect(h.snapshots, hasLength(1));
    _expectSettled(
      h.snapshots.single,
      visible: 'First page',
      notBefore: const Duration(milliseconds: 300) + _settle,
    );
    expect(h.routeChanges().last.data['navigation'], 'route_push');
    expect(h.routeInventories().last['routeKey'], '/first');
  });

  testWidgets('pop: captured after the departing page is gone', (tester) async {
    final h = _Harness(tester);
    await h.mount();
    h.push('First page', pageRoute('First page'));
    await h.frames(const Duration(seconds: 2));
    await waitForTugboatCaptureWork(tester);

    h.markStart();
    h.navigator.pop();
    await h.frames(const Duration(seconds: 2));
    await waitForTugboatCaptureWork(tester);

    expect(h.snapshots, hasLength(1));
    _expectSettled(
      h.snapshots.single,
      visible: 'Home page',
      notBefore: const Duration(milliseconds: 300) + _settle,
    );
    expect(h.routeChanges().last.data['navigation'], 'route_pop');
  });

  for (final (name, forward, reverse) in [
    (
      'longer',
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 900),
    ),
    (
      'shorter',
      const Duration(milliseconds: 600),
      const Duration(milliseconds: 50),
    ),
  ]) {
    testWidgets('pop whose reverse duration is $name than the forward '
        'duration: captured after the reverse run ends', (tester) async {
      final h = _Harness(tester);
      // The pop's deadline comes from the destination (home) route's forward
      // duration, not the popped route's reverse duration.
      await h.mount(
        home: () =>
            pageRoute('Home page', forward: const Duration(milliseconds: 300)),
      );
      h.push(
        'First page',
        pageRoute('First page', forward: forward, reverse: reverse),
      );
      await h.frames(const Duration(seconds: 2));
      await waitForTugboatCaptureWork(tester);

      h.markStart();
      h.navigator.pop();
      await h.frames(const Duration(seconds: 3));
      await waitForTugboatCaptureWork(tester);

      expect(h.snapshots, hasLength(1));
      final deadline = const Duration(milliseconds: 300) + _settle;
      _expectSettled(
        h.snapshots.single,
        visible: 'Home page',
        notBefore: reverse > deadline ? reverse : deadline,
      );
      expect(h.routeChanges().last.data.containsKey('captureOutcome'), isFalse);
    });
  }

  testWidgets('a push that interrupts a running push: only the second is '
      'captured, after both transitions', (tester) async {
    final h = _Harness(tester);
    await h.mount();

    h.markStart();
    h.push('First page', pageRoute('First page'));
    await h.frames(const Duration(milliseconds: 100));
    h.push('Second page', pageRoute('Second page'));
    await h.frames(const Duration(seconds: 2));
    await waitForTugboatCaptureWork(tester);

    expect(h.snapshots, hasLength(1));
    _expectSettled(
      h.snapshots.single,
      visible: 'Second page',
      notBefore: const Duration(milliseconds: 100 + 300) + _settle,
    );
    final changes = h.routeChanges();
    expect(changes.where((e) => e.data['route'] == '/first'), isEmpty);
    expect(changes.last.data['route'], '/second');
    expect(h.routeInventories().last['routeKey'], '/second');
  });

  testWidgets('a pop that interrupts a running push: captured after the '
      'reversed page is gone', (tester) async {
    final h = _Harness(tester);
    await h.mount();

    h.markStart();
    h.push('First page', pageRoute('First page'));
    await h.frames(const Duration(milliseconds: 100));
    h.navigator.pop();
    await h.frames(const Duration(seconds: 2));
    await waitForTugboatCaptureWork(tester);

    expect(h.snapshots, hasLength(1));
    _expectSettled(
      h.snapshots.single,
      visible: 'Home page',
      notBefore: const Duration(milliseconds: 100 + 300) + _settle,
    );
    final changes = h.routeChanges();
    expect(changes.last.data['navigation'], 'route_pop');
    expect(changes.last.data['route'], '/home');
  });
}

void _instantCases() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a route with Duration.zero transitions: captured after '
      'settleDelay with the covered page offstage', (tester) async {
    final h = _Harness(tester);
    await h.mount();

    h.markStart();
    h.push(
      'First page',
      pageRoute('First page', forward: Duration.zero, reverse: Duration.zero),
    );
    await h.frames(const Duration(seconds: 1));
    await waitForTugboatCaptureWork(tester);

    expect(h.snapshots, hasLength(1));
    _expectSettled(
      h.snapshots.single,
      visible: 'First page',
      notBefore: _settle,
    );
  });

  testWidgets('a route that is not a TransitionRoute: captured after '
      'settleDelay with the covered page offstage', (tester) async {
    final h = _Harness(tester);
    await h.mount();

    h.markStart();
    h.push('First page', _InstantRoute('First page'));
    await h.frames(const Duration(seconds: 1));
    await waitForTugboatCaptureWork(tester);

    expect(h.snapshots, hasLength(1));
    _expectSettled(
      h.snapshots.single,
      visible: 'First page',
      notBefore: _settle,
    );
    expect(h.routeChanges().last.data['route'], '/first');
  });
}

void _realPathCases() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a route with Duration.zero transitions: its route inventory '
      'lists only the destination page', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _config, child: child!),
        home: _page('Home page'),
      ),
    );
    await waitForTugboatCaptureWork(tester);
    final before = TugboatReplay.controller!.session!.events.length;

    navigatorKey.currentState!.push(
      pageRoute('First page', forward: Duration.zero, reverse: Duration.zero),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await waitForTugboatCaptureWork(tester);

    final events = TugboatReplay.controller!.session!.events.skip(before);
    final change = events.singleWhere((e) => e.type == 'route_change');
    expect(change.data['route'], '/first');
    expect(change.afterFrame, isNotNull);
    final inventory = events.singleWhere(
      (e) => e.type == 'scene_inventory' && e.data['trigger'] == 'route',
    );
    expect(inventory.data['routeKey'], '/first');
    expect(inventory.data['elements'], hasLength(1));
  });
}
