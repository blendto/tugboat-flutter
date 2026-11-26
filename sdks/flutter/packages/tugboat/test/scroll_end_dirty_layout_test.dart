import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// A device run logged `[tugboat] queued scroll_end task failed: ...
// '!debugNeedsLayout'` from RenderFractionalTranslation.hitTestChildren: an
// auto-scrolling marquee on a paywall ends programmatic scrolls, and the
// exploration scroll-end inventory hit-tested the tree while its layout was
// dirty. The failure is caught, but the inventory is lost and, in release,
// hit tests would read stale boxes.
//
// A programmatic scroll (no frame) now builds an inventory only for the
// viewport semantic map; its scene inventory is left to the re-sample. These
// tests follow the semantic maps, which still take the laid-out-tree path.

const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  emitViewportSemanticMap: true,
  viewportSemanticMode: TugboatViewportSemanticMode.full,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

Widget _marqueePage(ScrollController controller) => Scaffold(
  body: Column(
    children: [
      SizedBox(
        height: 120,
        child: ListView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          children: [
            for (var i = 0; i < 12; i++)
              SizedBox(width: 120, child: Center(child: Text('Badge $i'))),
          ],
        ),
      ),
      FractionalTranslation(
        key: const Key('subscribe'),
        translation: const Offset(0, 0.1),
        child: FilledButton(onPressed: () {}, child: const Text('Subscribe')),
      ),
    ],
  ),
);

/// Viewport semantic maps built for a scroll notification.
List<Map<String, Object?>> _scrollInventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'viewport_semantic_map' &&
        event.data['scrollContext'] != null)
      event.data,
];

/// Scene inventories a programmatic scroll emitted: none now.
List<Map<String, Object?>> _scrollSceneInventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory' && event.data['trigger'] == 'scroll')
      event.data,
];

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a programmatic scroll end with dirty layout waits for the '
      'frame instead of hit-testing', (tester) async {
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logs.add('$message');
    try {
      await _scrollWithDirtyLayout(tester, logs);
    } finally {
      debugPrint = previous;
    }
  });

  testWidgets('with clean layout the scroll-end inventory is built at once', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _exploration, child: child!),
        home: _marqueePage(controller),
      ),
    );
    await waitForTugboatCaptureWork(tester);
    final before = _scrollInventories().length;

    // A programmatic scroll that moves no pixel: nothing is dirty and no
    // frame is pending, so the inventory is built without waiting for one.
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final context = scrollable.notificationContext!;
    ScrollStartNotification(
      metrics: scrollable.position.copyWith(),
      context: context,
    ).dispatch(context);
    ScrollEndNotification(
      metrics: scrollable.position.copyWith(),
      context: context,
    ).dispatch(context);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    await tester.idle();

    // One for the start, one for the end.
    expect(_scrollInventories().length, before + 2);
    expect(_scrollSceneInventories(), isEmpty);
    // Releases the SDK's semantics handle.
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _scrollWithDirtyLayout(
  WidgetTester tester,
  List<String> logs,
) async {
  final controller = ScrollController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _exploration, child: child!),
      home: _marqueePage(controller),
    ),
  );
  await waitForTugboatCaptureWork(tester);
  final before = _scrollInventories().length;

  // The marquee moves between frames while the button needs layout.
  tester
      .renderObject<RenderFractionalTranslation>(
        find.byKey(const Key('subscribe')),
      )
      .markNeedsLayout();
  controller.jumpTo(240);
  await tester.idle();
  expect(logs.where((line) => line.contains('[tugboat]')), isEmpty);

  await tester.pump();
  await waitForTugboatCaptureWork(tester);
  expect(_scrollInventories().length, greaterThan(before));
  expect(logs.where((line) => line.contains('[tugboat]')), isEmpty);
  // Releases the SDK's semantics handle.
  await tester.pumpWidget(const SizedBox());
}
