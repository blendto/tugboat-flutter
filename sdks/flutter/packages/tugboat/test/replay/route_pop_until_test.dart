import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

/// `Navigator.popUntil` pops several routes in one synchronous turn. It is one
/// `route_pop` (BLE-709): the remaining stack, `fromRoute` the screen that was
/// on top, and the tap that caused it as its cause.
void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  testWidgets('popUntil the first route is one route_pop with the tap cause', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        initialRoute: '/home',
        navigatorObservers: <NavigatorObserver>[
          TugboatReplay.navigatorObserver,
        ],
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
    var serial = 0;
    late TugboatReplayController controller;
    for (var i = 0; i < 50 && TugboatReplay.controller == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    controller = TugboatReplay.controller!;
    controller.debugExecuteCapture =
        ({required trigger, required force}) async => controller.debugSeedFrame(
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
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
            child: const Text('Back to home'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cursor = controller.session!.events.length;
    await tester.tap(find.byKey(const Key('back-home')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    final pops = controller.session!.events
        .skip(cursor)
        .where(
          (e) =>
              e.type == 'route_change' && e.data['navigation'] == 'route_pop',
        )
        .toList();
    expect(pops, hasLength(1));
    final pop = pops.single.data;
    expect(pop['route'], '/home');
    expect(pop['fromRoute'], '/payment');
    expect(pop['stackRevision'], 1);
    expect(pop['causeEventId'], isNotNull);
    expect(pop['causeGesture'], 'tap');
    expect(pop['navigationOrigin'], 'interaction');
    expect([for (final r in pop['routeStack'] as List) (r as Map)['route']], [
      '/home',
    ]);

    navigator.push<void>(_page('/profile', const Text('profile')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final push = controller.session!.events
        .where(
          (e) =>
              e.type == 'route_change' && e.data['route'] == '/profile',
        )
        .single
        .data;
    expect([for (final r in push['routeStack'] as List) (r as Map)['route']], [
      '/home',
      '/profile',
    ]);
  });
}

Route<void> _page(String name, Widget child) => MaterialPageRoute<void>(
  settings: RouteSettings(name: name),
  builder: (_) => Scaffold(body: Center(child: child)),
);
