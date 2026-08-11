import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/replay_coherence_harness.dart';

void main() {
  test(
    'completed tap publishes one canonical interaction with frame ownership',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      final before = harness.seedRouteState(route: '/home', signature: 'home');

      harness.controller.recordPointerDown(const Offset(12, 12));
      harness.controller.recordPointerUp(const Offset(12, 12));
      await harness.flushScheduler();

      final interaction = harness.controller.session!
          .ofType('interaction')
          .single;
      expect(interaction.data['gesture'], 'tap');
      expect(interaction.beforeFrame, before);
      expect(interaction.afterFrame, isNotNull);
    },
  );

  test(
    'claimed route links its canonical interaction and destination frame',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      harness.seedRouteState(route: '/home', signature: 'home');

      harness.controller.recordPointerDown(const Offset(12, 12));
      final route = harness.controller.route(
        'route_push',
        harness.route('/next'),
      );
      harness.controller.recordPointerUp(const Offset(12, 12));
      await harness.flushScheduler();
      await route;

      final session = harness.controller.session!;
      final interaction = session.ofType('interaction').single;
      final routeChange = session.ofType('route_change').single;
      expect(routeChange.data['causeEventId'], interaction.id);
      expect(interaction.afterFrame, routeChange.afterFrame);
    },
  );

  test(
    'session replacement finalizes an in-flight gesture as cancelled',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(12, 12));
      final old = harness.controller.session!;
      harness.controller.start(const Size(390, 844), 'replacement');
      await harness.flushScheduler();

      expect(old.ofType('interaction'), hasLength(1));
      expect(old.ofType('interaction').single.data['gesture'], 'cancelled');
      expect(harness.controller.session!.ofType('interaction'), isEmpty);
    },
  );

  test(
    'duplicate pointer cancels prior interaction and keeps successor',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(12, 12));
      harness.controller.recordPointerUp(const Offset(12, 12));
      harness.controller.recordPointerDown(const Offset(18, 18));
      harness.controller.recordPointerUp(const Offset(18, 18));
      await harness.flushScheduler();

      final interactions = harness.controller.session!.ofType('interaction');
      expect(interactions, hasLength(2));
      expect(interactions.first.data['gesture'], 'cancelled');
      expect(interactions.last.data['gesture'], 'tap');
    },
  );

  test('swipe cannot claim a following route', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 12));
    harness.controller.markPendingTapAsSwipe(0);
    harness.controller.recordPointerUp(const Offset(12, 80));
    final route = harness.controller.route(
      'route_push',
      harness.route('/next'),
    );
    await harness.flushScheduler();
    await route;

    final session = harness.controller.session!;
    expect(session.ofType('interaction').single.data['gesture'], 'swipe');
    expect(
      session.ofType('route_change').single.data,
      isNot(contains('causeEventId')),
    );
  });

  test('cancelled interaction cannot claim a following route', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 12));
    harness.controller.recordPointerCancel(const Offset(12, 12));
    final route = harness.controller.route(
      'route_push',
      harness.route('/next'),
    );
    await harness.flushScheduler();
    await route;

    final session = harness.controller.session!;
    expect(session.ofType('interaction').single.data['gesture'], 'cancelled');
    expect(session.ofType('route_change').single.data['causeEventId'], isNull);
  });

  test(
    'session end terminalizes an in-flight tap capture without a late frame',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final before = harness.seedRouteState(route: '/home', signature: 'home');
      harness.capturer.blockNext = true;
      harness.controller.recordPointerDown(const Offset(12, 12));
      harness.controller.recordPointerUp(const Offset(12, 12));
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);

      await harness.controller.endSession();
      harness.capturer.completeBlocked('late-tap-frame');
      await harness.pumpQueueWork();

      expect(harness.controller.session!.ofType('interaction'), isEmpty);
      expect(harness.controller.latestFrameId, before);
    },
  );

  test('lifecycle pause terminalizes an in-flight swipe capture', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    final before = harness.seedRouteState(route: '/list', signature: 'list');
    harness.capturer.blockNext = true;
    harness.controller.recordPointerDown(const Offset(10, 100));
    harness.controller.markPendingTapAsSwipe(0);
    harness.controller.recordPointerUp(const Offset(10, 10));
    await harness.pumpQueueWork();
    expect(harness.capturer.blockedCount, 1);

    harness.controller.recordAppLifecycleState(AppLifecycleState.paused);
    final interaction = harness.controller.session!
        .ofType('interaction')
        .single;
    expect(interaction.data['gesture'], 'swipe');
    expect(interaction.afterFrame, isNull);
    harness.capturer.completeBlocked('late-swipe-frame');
    await harness.pumpQueueWork();
    expect(harness.controller.latestFrameId, before);
  });

  testWidgets('session end terminalizes a pointer-linked scroll capture', (
    tester,
  ) async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    await _mountScrollableHarness(tester, harness);

    final before = harness.seedRouteState(route: '/list', signature: 'list');
    harness.capturer.blockNext = true;
    harness.controller.recordPointerDown(const Offset(10, 10));
    harness.controller.markPendingTapAsSwipe(0);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    harness.controller.recordPointerUp(const Offset(10, -190));
    await harness.pumpQueueWork();
    expect(harness.capturer.blockedCount, 1);

    await harness.controller.endSession();
    harness.capturer.completeBlocked('late-scroll-frame');
    await harness.pumpQueueWork();

    final scrollsAfterEnd = harness.controller.session!
        .ofType('interaction')
        .where((event) => event.data['gesture'] == 'scroll')
        .toList(growable: false);
    expect(scrollsAfterEnd, hasLength(1));
    expect(scrollsAfterEnd.single.afterFrame, isNull);
    expect(harness.controller.latestFrameId, before);
    harness.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'session replacement terminalizes an unresolved pointer-linked scroll',
    (tester) async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      await _mountScrollableHarness(tester, harness);

      harness.seedRouteState(route: '/list', signature: 'list');
      harness.capturer.blockNext = true;
      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.controller.markPendingTapAsSwipe(0);
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      harness.controller.recordPointerUp(const Offset(10, -190));
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);

      final oldSession = harness.controller.session!;
      harness.controller.start(const Size(390, 844), 'replacement');

      final terminalScrolls = oldSession
          .ofType('interaction')
          .where((event) => event.data['gesture'] == 'scroll')
          .toList(growable: false);
      expect(terminalScrolls, hasLength(1));
      expect(terminalScrolls.single.afterFrame, isNull);
      expect(harness.controller.session!.ofType('interaction'), isEmpty);

      harness.capturer.completeBlocked('late-replacement-scroll-frame');
      await harness.pumpQueueWork();
      expect(
        oldSession
            .ofType('interaction')
            .where((event) => event.data['gesture'] == 'scroll'),
        hasLength(1),
      );
      expect(harness.controller.session!.ofType('interaction'), isEmpty);

      harness.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  test(
    'route epoch isolation never gives destination interaction the origin frame',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final origin = harness.seedRouteState(
        route: '/origin',
        signature: 'origin',
      );
      final originEpoch = harness.controller.debugRouteEpoch;
      final route = harness.controller.route(
        'route_push',
        harness.route(
          '/destination',
          transitionDuration: const Duration(milliseconds: 20),
        ),
      );
      harness.controller.recordPointerDown(const Offset(12, 12));
      harness.controller.recordPointerUp(const Offset(12, 12));
      await harness.flushScheduler();
      await route;

      final session = harness.controller.session!;
      final interaction = session.ofType('interaction').single;
      final change = session.ofType('route_change').single;
      final provenance = harness.controller.debugFrameProvenance(
        change.afterFrame!,
      )!;
      expect(interaction.beforeFrame, isNull);
      expect(interaction.beforeFrame, isNot(origin));
      expect(change.data['route'], '/destination');
      expect(provenance['route'], '/destination');
      expect(provenance['routeEpoch'], greaterThan(originEpoch));
    },
  );

  test(
    'trimmed frame provenance remains a tombstone and cannot be reused',
    () async {
      final harness = ReplayCoherenceHarness(maxFrames: 1);
      await harness.setUp();
      addTearDown(harness.dispose);
      await harness.flushScheduler();

      final route = harness.controller.route(
        'route_push',
        harness.route('/home'),
      );
      await harness.flushScheduler();
      await route;
      final first = harness.controller.session!
          .ofType('route_change')
          .single
          .afterFrame!;
      final second = harness.controller.debugSeedFrame(contentHash: 'second');

      expect(harness.controller.session!.frames.map((frame) => frame.id), [
        second,
      ]);
      expect(
        harness.controller.debugFrameProvenance(first),
        containsPair('available', false),
      );
      expect(harness.controller.debugReuseFrameForCurrentRoute(first), isNull);
    },
  );
}

Future<void> _mountScrollableHarness(
  WidgetTester tester,
  ReplayCoherenceHarness harness,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollStartNotification) {
            harness.controller.recordScrollStart(
              scrollContext: notification.context,
              metrics: notification.metrics,
              depth: notification.depth,
            );
          } else if (notification is ScrollUpdateNotification) {
            harness.controller.recordScrollUpdate(
              scrollContext: notification.context,
              metrics: notification.metrics,
            );
          } else if (notification is ScrollEndNotification) {
            harness.controller.recordScrollEnd(
              scrollContext: notification.context,
              metrics: notification.metrics,
            );
          }
          return false;
        },
        child: ListView(
          children: List<Widget>.generate(
            30,
            (index) => SizedBox(height: 80, child: Text('$index')),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
