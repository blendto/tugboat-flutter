import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

const _scrollTestConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: true,
  scrollCaptureInterval: Duration(milliseconds: 50),
  captureScrollSamples: true,
  capturePixelRatio: 1.0,
);

Future<void> _waitForCaptures(WidgetTester tester) async {
  final controller = TugboatReplay.controller;
  if (controller != null) {
    controller.debugExecuteCapture =
        ({required trigger, required force}) async {
          return controller.debugSeedFrame(trigger: trigger);
        };
  }
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pump();
}

Future<void> _exerciseScrollCallbackOrder(
  WidgetTester tester, {
  required bool endBeforePointerUp,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
      home: Scaffold(
        body: ListView.builder(
          itemCount: 30,
          itemBuilder: (context, index) => Text('Callback item $index'),
        ),
      ),
    ),
  );
  await _waitForCaptures(tester);

  final listContext = tester.element(find.byType(Scrollable));
  final metrics = Scrollable.of(
    tester.element(find.text('Callback item 0')),
  ).position;
  final controller = TugboatReplay.controller!;
  final initialInteractionRequests = controller.session!.events
      .where(
        (event) =>
            event.type == 'capture_diagnostic' &&
            event.data['trigger'] == 'interaction',
      )
      .length;
  controller.recordPointerDown(const Offset(20, 20));
  controller.markPendingTapAsSwipe(0);
  controller.recordScrollStart(
    scrollContext: listContext,
    metrics: metrics,
    depth: 0,
  );
  if (endBeforePointerUp) {
    controller.recordScrollEnd(scrollContext: listContext, metrics: metrics);
    controller.recordPointerUp(const Offset(20, -100));
  } else {
    controller.recordPointerUp(const Offset(20, -100));
    controller.recordScrollEnd(scrollContext: listContext, metrics: metrics);
  }
  await tester.pump();
  await _waitForCaptures(tester);

  final session = controller.session!;
  final interactions = session.events
      .where(
        (event) =>
            event.type == 'interaction' &&
            event.stream == TugboatEventStream.semantic &&
            event.data['gesture'] == 'scroll',
      )
      .toList();
  expect(interactions, hasLength(1));
  final afterFrame = interactions.single.afterFrame;
  expect(afterFrame, isNotNull);
  final frame = session.frameById(afterFrame!);
  expect(frame, isNotNull);
  expect(frame!.trigger, TugboatFrameTrigger.interaction);
  expect(
    session.events
        .where(
          (event) =>
              event.type == 'capture_diagnostic' &&
              event.data['trigger'] == 'interaction',
        )
        .length,
    initialInteractionRequests + 1,
  );
}

void main() {
  testWidgets('scroll end before pointer up joins one interaction capture', (
    tester,
  ) async {
    await _exerciseScrollCallbackOrder(tester, endBeforePointerUp: true);
  });

  testWidgets('pointer up before scroll end joins one interaction capture', (
    tester,
  ) async {
    await _exerciseScrollCallbackOrder(tester, endBeforePointerUp: false);
  });

  testWidgets('one scroll start has one pointer owner', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: ListView.builder(
            itemCount: 30,
            itemBuilder: (context, index) => Text('Owner item $index'),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    final controller = TugboatReplay.controller!;
    controller.debugExecuteCapture =
        ({required trigger, required force}) async {
          return controller.debugSeedFrame(trigger: trigger);
        };
    final listContext = tester.element(find.byType(Scrollable));
    final metrics = Scrollable.of(
      tester.element(find.text('Owner item 0')),
    ).position;
    controller.recordPointerDown(const Offset(20, 120), pointer: 1);
    controller.recordPointerDown(const Offset(40, 120), pointer: 2);
    controller.markPendingTapAsSwipe(1);
    controller.markPendingTapAsSwipe(2);
    controller.recordScrollStart(
      scrollContext: listContext,
      metrics: metrics,
      depth: 0,
    );
    controller.recordPointerUp(const Offset(20, 20), pointer: 1);
    controller.recordPointerUp(const Offset(40, 20), pointer: 2);
    controller.recordScrollEnd(scrollContext: listContext, metrics: metrics);
    await _waitForCaptures(tester);
    await _waitForCaptures(tester);

    final interactions = controller.session!.events
        .where((event) => event.type == 'interaction')
        .toList();
    expect(interactions, hasLength(2));
    expect(interactions.map((event) => event.data['gesture']).toSet(), {
      'scroll',
      'swipe',
    });
    expect(interactions.map((event) => event.id).toSet(), hasLength(2));
  });

  testWidgets(
    'programmatic scroll emits evidence without interaction capture',
    (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
          home: Scaffold(
            body: ListView.builder(
              controller: scrollController,
              itemCount: 40,
              itemBuilder: (context, index) => Text('Program item $index'),
            ),
          ),
        ),
      );
      await _waitForCaptures(tester);
      final controller = TugboatReplay.controller!;
      final interactionRequestCount = controller.session!.events
          .where(
            (event) =>
                event.type == 'capture_diagnostic' &&
                event.data['trigger'] == 'interaction',
          )
          .length;

      scrollController.animateTo(
        180,
        duration: const Duration(milliseconds: 32),
        curve: Curves.linear,
      );
      await tester.pumpAndSettle();
      await _waitForCaptures(tester);

      final session = controller.session!;
      expect(session.scrollSamples, isNotEmpty);
      expect(
        session.events.where(
          (event) =>
              event.type == 'interaction' &&
              event.stream == TugboatEventStream.semantic,
        ),
        isEmpty,
      );
      expect(
        session.events
            .where(
              (event) =>
                  event.type == 'capture_diagnostic' &&
                  event.data['trigger'] == 'interaction',
            )
            .length,
        interactionRequestCount,
      );
    },
  );

  testWidgets('ListView scroll carries scrollable target anchor', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: ListView.builder(
            itemCount: 40,
            itemBuilder: (context, index) =>
                ListTile(title: Text('Scroll item $index')),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final scrollInteractions = session.events
        .where(
          (event) =>
              event.type == 'interaction' &&
              event.stream == TugboatEventStream.semantic &&
              event.data['gesture'] == 'scroll',
        )
        .toList();

    expect(scrollInteractions, isNotEmpty);
    expect(scrollInteractions.first.data['targetFingerprint'], isNotNull);
    expect(scrollInteractions.first.data['targetFingerprint'], isNotEmpty);
    final payload = Map<String, Object?>.from(
      scrollInteractions.first.data['payload']! as Map,
    );
    expect(payload['startOffset'], isNotNull);
    expect(payload['endOffset'], isNotNull);
    expect(payload['endOffset'], isNot(equals(payload['startOffset'])));
  });

  testWidgets(
    'scroll samples do not request in-motion screenshots by default',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
          home: Scaffold(
            body: ListView.builder(
              itemCount: 40,
              itemBuilder: (context, index) => Text('Metrics item $index'),
            ),
          ),
        ),
      );
      await _waitForCaptures(tester);
      final controller = TugboatReplay.controller!;
      final listContext = tester.element(find.byType(Scrollable));
      final metrics = Scrollable.of(
        tester.element(find.text('Metrics item 0')),
      ).position;
      final scrollCapturesBefore = controller.session!.events
          .where(
            (event) =>
                event.type == 'capture_diagnostic' &&
                event.data['trigger'] == 'scroll',
          )
          .length;

      controller.recordScrollStart(
        scrollContext: listContext,
        metrics: metrics,
        depth: 0,
      );
      controller.recordScrollUpdate(
        scrollContext: listContext,
        metrics: metrics,
      );
      await tester.pump();

      expect(controller.session!.scrollSamples.length, greaterThan(1));
      expect(
        controller.session!.events
            .where(
              (event) =>
                  event.type == 'capture_diagnostic' &&
                  event.data['trigger'] == 'scroll',
            )
            .length,
        scrollCapturesBefore,
      );
    },
  );

  testWidgets(
    'in-motion screenshots are independent from scroll sample retention',
    (tester) async {
      const config = TugboatReplayConfig(
        profile: TugboatCaptureProfile.exploration,
        settleDelay: Duration.zero,
        interactionClaimWindow: Duration.zero,
        enableGlobalPointerCapture: true,
        scrollCaptureInterval: Duration.zero,
        captureScrollSamples: false,
        captureScrollScreenshots: true,
        capturePixelRatio: 1.0,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TugboatReplay.wrapApp(config: config, child: child!),
          home: Scaffold(
            body: ListView.builder(
              itemCount: 40,
              itemBuilder: (context, index) => Text('Visual item $index'),
            ),
          ),
        ),
      );
      await _waitForCaptures(tester);
      final controller = TugboatReplay.controller!;
      final listContext = tester.element(find.byType(Scrollable));
      final metrics = Scrollable.of(
        tester.element(find.text('Visual item 0')),
      ).position;

      controller.recordScrollStart(
        scrollContext: listContext,
        metrics: metrics,
        depth: 0,
      );
      controller.recordScrollUpdate(
        scrollContext: listContext,
        metrics: metrics,
      );
      await _waitForCaptures(tester);

      expect(controller.session!.scrollSamples, isEmpty);
      expect(
        controller.session!.events.where(
          (event) =>
              event.type == 'capture_diagnostic' &&
              event.data['trigger'] == 'scroll',
        ),
        isNotEmpty,
      );
    },
  );

  testWidgets('dead swipe on static widget emits one swipe interaction', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              key: Key('static-block'),
              width: 200,
              height: 200,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(
      find.byKey(const Key('static-block')),
      const Offset(0, -120),
    );
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final swipes = session.events
        .where(
          (event) =>
              event.type == 'interaction' && event.data['gesture'] == 'swipe',
        )
        .toList();
    final scrollInteractions = session.events
        .where(
          (event) =>
              event.type == 'interaction' &&
              event.stream == TugboatEventStream.semantic &&
              event.data['gesture'] == 'scroll',
        )
        .toList();

    expect(swipes, isNotEmpty);
    expect(swipes.first.data['gesture'], 'swipe');
    expect(scrollInteractions, isEmpty);
  });

  testWidgets('scroll swipe resolves as a scroll interaction', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: ListView.builder(
            itemCount: 30,
            itemBuilder: (context, index) =>
                ListTile(title: Text('Linked scroll $index')),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final scrolls = session.events
        .where(
          (event) =>
              event.type == 'interaction' && event.data['gesture'] == 'scroll',
        )
        .toList();

    expect(scrolls, isNotEmpty);
    expect(scrolls.first.data['payload'], isA<Map>());
  });

  testWidgets('sub-slop tap emits one canonical tap interaction', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Tap me')),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.tap(find.text('Tap me'));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    expect(
      session.events.where(
        (event) =>
            event.type == 'interaction' && event.data['gesture'] == 'tap',
      ),
      hasLength(1),
    );
    expect(
      session.events.where(
        (event) =>
            event.type == 'interaction' && event.data['gesture'] == 'swipe',
      ),
      isEmpty,
    );
  });

  testWidgets('TugboatSubView scroll emits scroll interaction', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: TugboatSubView(
            label: 'feed-section',
            child: ListView.builder(
              itemCount: 25,
              itemBuilder: (context, index) =>
                  ListTile(title: Text('Section item $index')),
            ),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await _waitForCaptures(tester);

    final scrollInteractions = TugboatReplay.controller!.session!.events
        .where(
          (event) =>
              event.type == 'interaction' &&
              event.stream == TugboatEventStream.semantic &&
              event.data['gesture'] == 'scroll',
        )
        .toList();
    expect(scrollInteractions, isNotEmpty);
  });

  testWidgets('nested scrollables produce independent scroll pairs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: ListView(
            children: [
              SizedBox(
                height: 120,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: 8,
                  itemBuilder: (context, index) => Container(
                    width: 100,
                    margin: const EdgeInsets.all(4),
                    color: Colors.primaries[index % Colors.primaries.length],
                  ),
                ),
              ),
              for (var i = 0; i < 20; i++)
                ListTile(title: Text('Outer row $i')),
            ],
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    final horizontalList = find.byWidgetPredicate(
      (widget) =>
          widget is ListView && widget.scrollDirection == Axis.horizontal,
    );
    final verticalList = find.byWidgetPredicate(
      (widget) => widget is ListView && widget.scrollDirection == Axis.vertical,
    );
    await tester.drag(horizontalList, const Offset(-120, 0));
    await _waitForCaptures(tester);
    await tester.drag(verticalList, const Offset(0, -180));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final scrollInteractions = session.events
        .where(
          (event) =>
              event.type == 'interaction' &&
              event.stream == TugboatEventStream.semantic &&
              event.data['gesture'] == 'scroll',
        )
        .toList();

    expect(scrollInteractions.length, greaterThanOrEqualTo(2));
    final axes = session.scrollSamples.map((sample) => sample.axis).toSet();
    expect(axes, containsAll(['horizontal', 'vertical']));
  });

  testWidgets('PageView scroll updates horizontal scroll samples', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: PageView(
            children: const [
              ColoredBox(color: Colors.red),
              ColoredBox(color: Colors.green),
              ColoredBox(color: Colors.blue),
            ],
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    expect(
      session.scrollSamples.any((sample) => sample.axis == 'horizontal'),
      isTrue,
    );
    expect(session.scrollSamples.length, greaterThan(1));
  });
}
