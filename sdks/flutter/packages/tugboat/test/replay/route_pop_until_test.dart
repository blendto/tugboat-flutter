import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

/// `Navigator.popUntil` pops several routes in one synchronous turn. It is one
/// `route_pop` (BLE-709): the remaining stack, `fromRoute` the screen that was
/// on top, and the tap that caused it as its cause (`same_turn`, as for a
/// single pop).
void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  testWidgets('popUntil the first route is one route_pop with the tap cause', (
    tester,
  ) async {
    final fixture = await _mount(tester, (context) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    });

    final pop = await fixture.tapBack(tester);
    expect(pop['route'], '/home');
    expect(pop['fromRoute'], '/payment');
    expect(pop['stackRevision'], 1);
    expect(pop['causeEventId'], isNotNull);
    expect(pop['causeGesture'], 'tap');
    expect(pop['navigationOrigin'], 'interaction');
    expect(pop['interactionAttribution'], 'same_turn');
    expect(_routes(pop), ['/home']);

    fixture.navigator.push<void>(_page('/profile', const Text('profile')));
    await tester.pumpAndSettle();
    await fixture.settle(tester);
    final push = fixture.controller.session!.events
        .where((e) => e.type == 'route_change' && e.data['route'] == '/profile')
        .single
        .data;
    expect(_routes(push), ['/home', '/profile']);
  });

  testWidgets('a single pop keeps its cause as same_turn', (tester) async {
    final fixture = await _mount(tester, (context) {
      Navigator.of(context).pop();
    });

    final pop = await fixture.tapBack(tester);
    expect(pop['route'], '/shipping');
    expect(pop['fromRoute'], '/payment');
    expect(pop['causeEventId'], isNotNull);
    expect(pop['interactionAttribution'], 'same_turn');
    expect(_routes(pop), ['/home', '/cart', '/shipping']);
  });

  testWidgets('a pop is reported before a later route change on another '
      'navigator in the same turn', (tester) async {
    final rootKey = GlobalKey<NavigatorState>();
    final innerKey = GlobalKey<NavigatorState>();
    final innerObserver = TugboatReplay.createNavigatorObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootKey,
        navigatorObservers: <NavigatorObserver>[
          TugboatReplay.navigatorObserver,
        ],
        home: Navigator(
          key: innerKey,
          observers: <NavigatorObserver>[innerObserver],
          onGenerateRoute: (_) => _page('/inner', const Text('inner')),
        ),
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            enabled: true,
            settleDelay: Duration.zero,
            capturePixelRatio: 1,
          ),
          child: child!,
        ),
      ),
    );
    for (var i = 0; i < 50 && TugboatReplay.controller?.session == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final controller = TugboatReplay.controller!;
    var serial = 0;
    controller.debugExecuteCapture =
        ({required trigger, required force}) async => controller.debugSeedFrame(
          contentHash: 'order-${trigger.name}-${serial++}',
          trigger: trigger,
        );
    rootKey.currentState!.push<void>(_page('/dialog', const Text('dialog')));
    await tester.pumpAndSettle();
    final cursor = controller.session!.events.length;

    rootKey.currentState!.pop();
    innerKey.currentState!.push<void>(_page('/detail', const Text('detail')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    final kinds = [
      for (final e in controller.session!.events.skip(cursor))
        if (e.type == 'route_change') e.data['navigation'],
    ];
    expect(kinds, ['route_pop', 'route_push']);
  });
}

List<Object?> _routes(Map<String, Object?> data) => [
  for (final r in data['routeStack']! as List) (r as Map)['route'],
];

class _Fixture {
  _Fixture(this.controller, this.navigator);

  final TugboatReplayController controller;
  final NavigatorState navigator;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Taps `Back to home` and returns the one `route_pop` it caused.
  Future<Map<String, Object?>> tapBack(WidgetTester tester) async {
    final cursor = controller.session!.events.length;
    await tester.tap(find.byKey(const Key('back-home')));
    await tester.pumpAndSettle();
    await settle(tester);
    final pops = controller.session!.events
        .skip(cursor)
        .where(
          (e) =>
              e.type == 'route_change' && e.data['navigation'] == 'route_pop',
        )
        .toList();
    expect(pops, hasLength(1));
    return pops.single.data;
  }
}

/// Home, cart, shipping and payment, with `Back to home` on payment calling
/// [onBack].
Future<_Fixture> _mount(
  WidgetTester tester,
  void Function(BuildContext) onBack,
) async {
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      initialRoute: '/home',
      navigatorObservers: <NavigatorObserver>[TugboatReplay.navigatorObserver],
      routes: <String, WidgetBuilder>{
        '/home': (_) => const Scaffold(body: Text('home')),
      },
      builder: (context, child) => TugboatReplay.wrapApp(
        config: const TugboatReplayConfig(
          enabled: true,
          settleDelay: Duration.zero,
          enableGlobalPointerCapture: true,
          capturePixelRatio: 1,
        ),
        child: child!,
      ),
    ),
  );
  for (var i = 0; i < 50 && TugboatReplay.controller == null; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  final controller = TugboatReplay.controller!;
  var serial = 0;
  controller.debugExecuteCapture = ({required trigger, required force}) async =>
      controller.debugSeedFrame(
        contentHash: 'pop-until-${trigger.name}-${serial++}',
        trigger: trigger,
      );
  for (var i = 0; i < 50 && controller.session == null; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  controller.debugSeedFrame(
    contentHash: 'pop-until-initial-${serial++}',
    trigger: TugboatFrameTrigger.initial,
  );
  final navigator = navigatorKey.currentState!;
  navigator.pushReplacement<void, void>(_page('/home', const Text('home')));
  await tester.pumpAndSettle();
  navigator.push<void>(_page('/cart', const Text('cart')));
  await tester.pumpAndSettle();
  navigator.push<void>(_page('/shipping', const Text('shipping')));
  await tester.pumpAndSettle();
  navigator.push<void>(
    _page(
      '/payment',
      Builder(
        builder: (context) => TextButton(
          key: const Key('back-home'),
          onPressed: () => onBack(context),
          child: const Text('Back to home'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(controller, navigator);
}

Route<void> _page(String name, Widget child) => MaterialPageRoute<void>(
  settings: RouteSettings(name: name),
  builder: (_) => Scaffold(body: Center(child: child)),
);
