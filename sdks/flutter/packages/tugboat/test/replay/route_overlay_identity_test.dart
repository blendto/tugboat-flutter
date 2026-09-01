import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  testWidgets(
    'named popup then unnamed sheet records identity and presentation parent',
    (tester) async {
      final fixture = await _OverlayIdentityFixture.mount(tester);

      var eventCursor = fixture.eventCount;
      await tester.tap(find.byKey(_openPaywall));
      await tester.pumpAndSettle();
      final paywall = await fixture.route(
        tester,
        '/subscriptionPaywall',
        afterIndex: eventCursor,
      );

      expect(paywall.data['route'], '/subscriptionPaywall');
      expect(paywall.data['routeName'], '/subscriptionPaywall');
      expect(paywall.data['routeType'], isNot(contains('Dialog')));
      expect(paywall.data['routeNamed'], isTrue);
      expect(paywall.data['overlayKind'], TugboatOverlayKind.popup);
      expect(paywall.data['fromRoute'], '/home');
      expect(paywall.data['fromRouteName'], '/home');
      expect(paywall.data['fromRouteNamed'], isTrue);
      expect(paywall.data['presentedOverRoute'], '/home');
      expect(paywall.data['hostPageRoute'], '/home');
      expect(paywall.data['causeEventId'], isNotNull);
      expect(paywall.data['causeGesture'], 'tap');
      expect(paywall.data['causeTargetFingerprint'], isNotNull);
      expect(paywall.data['causeTargetFingerprint'], isNot(isEmpty));

      eventCursor = fixture.eventCount;
      await tester.tap(find.byKey(_openSheet));
      await tester.pumpAndSettle();
      final sheet = await fixture.routePush(tester, afterIndex: eventCursor);

      expect(sheet.data['route'], contains('ModalBottomSheetRoute'));
      expect(sheet.data.containsKey('routeName'), isFalse);
      expect(sheet.data['routeType'], contains('ModalBottomSheetRoute'));
      expect(sheet.data['routeNamed'], isFalse);
      expect(sheet.data['overlayKind'], TugboatOverlayKind.sheet);
      expect(sheet.data['fromRoute'], '/subscriptionPaywall');
      expect(sheet.data['fromRouteName'], '/subscriptionPaywall');
      expect(sheet.data['fromRouteNamed'], isTrue);
      expect(sheet.data['presentedOverRoute'], '/subscriptionPaywall');
      expect(sheet.data['presentedOverOverlayKind'], TugboatOverlayKind.popup);
      expect(sheet.data['hostPageRoute'], '/home');
      expect(sheet.data['hostPageRouteInstanceId'], isNotNull);
      expect(
        sheet.data['presentedOverRouteInstanceId'],
        paywall.data['routeInstanceId'],
      );

      final stack = (sheet.data['routeStack'] as List).cast<Map>();
      expect(stack, hasLength(3));
      expect(stack[0]['route'], '/home');
      expect(stack[0]['overlayKind'], TugboatOverlayKind.page);
      expect(stack[0]['routeNamed'], isTrue);
      expect(stack[1]['route'], '/subscriptionPaywall');
      expect(stack[1]['overlayKind'], TugboatOverlayKind.popup);
      expect(stack[2]['route'], contains('ModalBottomSheetRoute'));
      expect(stack[2]['overlayKind'], TugboatOverlayKind.sheet);
      expect(stack[2]['routeNamed'], isFalse);
      expect(sheet.data.containsKey('routeStackTruncated'), isFalse);
    },
  );

  testWidgets('exploration suppression still captures overlay after-frames', (
    tester,
  ) async {
    final fixture = await _OverlayIdentityFixture.mount(tester);
    fixture.controller.debugSetExplorationFramesSuppressed(true);

    var eventCursor = fixture.eventCount;
    await fixture.pushNamedPage(tester, '/details');
    final page = await fixture.route(
      tester,
      '/details',
      afterIndex: eventCursor,
    );
    expect(page.data['overlayKind'], TugboatOverlayKind.page);
    expect(page.data.containsKey('presentedOverRoute'), isFalse);
    expect(page.data['causeEventId'], isNull);
    expect(
      page.afterFrame,
      isNull,
      reason: 'unclaimed page pushes stay suppressed',
    );

    eventCursor = fixture.eventCount;
    await fixture.pushUnnamedSheet(tester);
    final sheet = await fixture.routePush(tester, afterIndex: eventCursor);
    expect(sheet.data['overlayKind'], TugboatOverlayKind.sheet);
    expect(sheet.data['causeEventId'], isNull);
    expect(
      sheet.afterFrame,
      isNotNull,
      reason: 'non-page overlays must still settle and capture',
    );
  });
}

const _openPaywall = Key('identity-open-paywall');
const _openSheet = Key('identity-open-sheet');
const _openPage = Key('identity-open-page');
const _openUnclaimedSheet = Key('identity-open-unclaimed-sheet');

class _OverlayIdentityFixture {
  _OverlayIdentityFixture(this.controller, this.navigatorKey);

  final TugboatReplayController controller;
  final GlobalKey<NavigatorState> navigatorKey;
  int _frameSerial = 0;

  TugboatSession get session => controller.session!;

  int get eventCount => session.events.length;

  static Future<_OverlayIdentityFixture> mount(WidgetTester tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        initialRoute: '/home',
        navigatorObservers: <NavigatorObserver>[
          TugboatReplay.navigatorObserver,
        ],
        routes: <String, WidgetBuilder>{'/home': (_) => const _HomePage()},
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.exploration,
            settleDelay: Duration.zero,
            enableGlobalPointerCapture: true,
            capturePixelRatio: 1,
          ),
          child: child!,
        ),
      ),
    );
    final controller = await _pumpUntil<TugboatReplayController>(
      tester,
      () => TugboatReplay.controller,
      'replay controller',
    );
    final fixture = _OverlayIdentityFixture(controller, navigatorKey);
    controller.debugExecuteCapture =
        ({required trigger, required force}) async => controller.debugSeedFrame(
          contentHash: 'identity-${trigger.name}-${fixture._frameSerial++}',
          trigger: trigger,
        );
    await _pumpUntil<TugboatSession>(
      tester,
      () => controller.session,
      'session',
    );
    controller.debugSeedFrame(
      contentHash: 'identity-initial-${fixture._frameSerial++}',
      trigger: TugboatFrameTrigger.initial,
    );
    await fixture.observeHome(tester);
    return fixture;
  }

  Future<TugboatEvent> route(
    WidgetTester tester,
    String name, {
    String navigation = 'route_push',
    required int afterIndex,
  }) => _pumpUntil<TugboatEvent>(tester, () {
    for (final event in session.events.skip(afterIndex)) {
      if (event.type == 'route_change' &&
          event.data['route'] == name &&
          event.data['navigation'] == navigation) {
        return event;
      }
    }
    return null;
  }, '$navigation $name');

  Future<TugboatEvent> routePush(
    WidgetTester tester, {
    required int afterIndex,
  }) => _pumpUntil<TugboatEvent>(tester, () {
    for (final event in session.events.skip(afterIndex)) {
      if (event.type == 'route_change' &&
          event.data['navigation'] == 'route_push') {
        return event;
      }
    }
    return null;
  }, 'route_push');

  Future<void> observeHome(WidgetTester tester) async {
    navigatorKey.currentState!.pushReplacement<void, void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/home'),
        builder: (_) => const _HomePage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pushNamedPage(WidgetTester tester, String name) async {
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => const _DetailsPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pushUnnamedSheet(WidgetTester tester) async {
    showModalBottomSheet<void>(
      context: navigatorKey.currentContext!,
      builder: (context) => const SizedBox(height: 80),
    );
    await tester.pumpAndSettle();
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: <Widget>[
        FilledButton(
          key: _openPaywall,
          onPressed: () => Navigator.of(context).push<void>(
            _PaywallRoute<void>(
              settings: const RouteSettings(name: '/subscriptionPaywall'),
            ),
          ),
          child: const Text('paywall'),
        ),
        FilledButton(
          key: _openPage,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/details'),
              builder: (_) => const _DetailsPage(),
            ),
          ),
          child: const Text('page'),
        ),
      ],
    ),
  );
}

class _DetailsPage extends StatelessWidget {
  const _DetailsPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FilledButton(
      key: _openUnclaimedSheet,
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        builder: (context) => const SizedBox(height: 80),
      ),
      child: const Text('sheet'),
    ),
  );
}

class _PaywallRoute<T> extends PopupRoute<T> {
  _PaywallRoute({super.settings});

  @override
  Color? get barrierColor => const Color(0x80000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'paywall';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Material(
    child: Center(
      child: FilledButton(
        key: _openSheet,
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          builder: (context) => const SizedBox(height: 80),
        ),
        child: const Text('open sheet'),
      ),
    ),
  );
}

Future<T> _pumpUntil<T>(
  WidgetTester tester,
  T? Function() read,
  String description,
) async {
  for (var index = 0; index < 120; index++) {
    final value = read();
    if (value != null) return value;
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('Timed out waiting for $description');
}
