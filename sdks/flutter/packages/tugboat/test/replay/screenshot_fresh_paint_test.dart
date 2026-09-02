import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/capture_boundary.dart';
import 'package:tugboat/src/health.dart';
import 'package:tugboat/src/replay_config.dart';
import 'package:tugboat/src/screenshot_capturer.dart';
import 'package:tugboat/src/screenshot_encode.dart';
import 'package:tugboat/src/screenshot_mask_level.dart';

Widget _scene(GlobalKey boundaryKey, Color color) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: TugboatCaptureBoundary(
      key: boundaryKey,
      child: ColoredBox(
        color: color,
        child: const SizedBox.square(dimension: 80),
      ),
    ),
  ),
);

Widget _plainRepaintScene(GlobalKey boundaryKey) => Directionality(
  textDirection: TextDirection.ltr,
  child: RepaintBoundary(
    key: boundaryKey,
    child: const SizedBox.square(dimension: 80),
  ),
);

Color _centerColor(ScreenshotCaptureResult result) {
  final decoded = img.decodeJpg(result.bytes)!;
  final pixel = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
  return Color.fromARGB(
    pixel.a.toInt(),
    pixel.r.toInt(),
    pixel.g.toInt(),
    pixel.b.toInt(),
  );
}

void main() {
  testWidgets('fresh capture observes the newer painted red to blue state', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final redFrame = Completer<void>();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      pixelRatio: 1,
      frameWaiter: () => redFrame.future,
      encoder: InlineScreenshotEncoder(),
    );
    await tester.pumpWidget(_scene(boundaryKey, Colors.red));

    final redFuture = capturer.captureAttempt(requireFreshPaint: true);
    await tester.pump();
    redFrame.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    final red = await redFuture;
    addTearDown(capturer.dispose);

    await tester.pumpWidget(_scene(boundaryKey, Colors.blue));
    final blueFrame = Completer<void>();
    final blueCapturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      pixelRatio: 1,
      frameWaiter: () => blueFrame.future,
      encoder: InlineScreenshotEncoder(),
    );
    addTearDown(blueCapturer.dispose);
    final blueFuture = blueCapturer.captureAttempt(requireFreshPaint: true);
    await tester.pump();
    blueFrame.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    final blue = await blueFuture;

    expect(red, isNotNull);
    expect(blue, isNotNull);
    expect(red.failure, isNull);
    expect(blue.failure, isNull);
    expect(red.result, isNotNull);
    expect(blue.result, isNotNull);
    expect(
      _centerColor(red.result!).r,
      greaterThan(_centerColor(red.result!).b),
    );
    expect(
      _centerColor(blue.result!).b,
      greaterThan(_centerColor(blue.result!).r),
    );
    expect(blue.result!.contentHash, isNot(red.result!.contentHash));
  });

  testWidgets('cancelled frame wait resolves without a deadlock', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final frame = Completer<void>();
    final cancelled = Completer<void>();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      frameWaiter: () => frame.future,
      encoder: InlineScreenshotEncoder(),
    );
    await tester.pumpWidget(_scene(boundaryKey, Colors.red));

    final pending = capturer.captureAttempt(
      requireFreshPaint: true,
      cancelled: cancelled.future,
      frameTimeout: const Duration(seconds: 30),
    );
    cancelled.complete();

    final attempt = await pending;
    expect(attempt.result, isNull);
    expect(attempt.failure, ScreenshotCaptureFailure.cancelled);
  });

  testWidgets('completed frame without a paint generation is classified', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      frameWaiter: () => Future<void>.value(),
      encoder: InlineScreenshotEncoder(),
    );
    await tester.pumpWidget(_scene(boundaryKey, Colors.red));

    final attempt = await capturer.captureAttempt(requireFreshPaint: true);
    expect(attempt.result, isNull);
    expect(attempt.failure, ScreenshotCaptureFailure.paintNotAdvanced);
  });

  testWidgets('plain repaint boundary cannot prove fresh paint', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      frameWaiter: () => Future<void>.value(),
      encoder: InlineScreenshotEncoder(),
    );
    await tester.pumpWidget(_plainRepaintScene(boundaryKey));

    final attempt = await capturer.captureAttempt(requireFreshPaint: true);
    expect(attempt.result, isNull);
    expect(attempt.failure, ScreenshotCaptureFailure.paintNotAdvanced);
  });

  testWidgets('frame wait timeout is bounded and classified', (tester) async {
    final boundaryKey = GlobalKey();
    final frame = Completer<void>();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      frameWaiter: () => frame.future,
      encoder: InlineScreenshotEncoder(),
    );
    await tester.pumpWidget(_scene(boundaryKey, Colors.red));

    final pending = capturer.captureAttempt(
      requireFreshPaint: true,
      frameTimeout: const Duration(milliseconds: 10),
    );
    await tester.pump(const Duration(milliseconds: 11));

    final attempt = await pending;
    expect(attempt.result, isNull);
    expect(attempt.failure, ScreenshotCaptureFailure.paintTimedOut);
  });

  testWidgets('a detached boundary is never captured after the frame wait', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final frame = Completer<void>();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      frameWaiter: () => frame.future,
      encoder: InlineScreenshotEncoder(),
    );
    await tester.pumpWidget(_scene(boundaryKey, Colors.red));

    final pending = capturer.captureAttempt(requireFreshPaint: true);
    await tester.pumpWidget(const SizedBox.shrink());
    frame.complete();

    final attempt = await pending;
    expect(attempt.result, isNull);
    expect(attempt.failure, ScreenshotCaptureFailure.boundaryDetached);
  });

  testWidgets('a replacement boundary is not mistaken for the requested one', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final frame = Completer<void>();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      frameWaiter: () => frame.future,
      encoder: InlineScreenshotEncoder(),
    );
    await tester.pumpWidget(_scene(boundaryKey, Colors.red));

    final pending = capturer.captureAttempt(requireFreshPaint: true);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: boundaryKey,
          child: const SizedBox.square(dimension: 80),
        ),
      ),
    );
    frame.complete();

    final attempt = await pending;
    expect(attempt.result, isNull);
    expect(attempt.failure, ScreenshotCaptureFailure.boundaryReplaced);
  });

  testWidgets(
    'paint-generation gate skips when unchanged, captures after repaint, force bypasses',
    (tester) async {
      final boundaryKey = GlobalKey();
      final capturer = ScreenshotCapturer(
        boundaryKey: boundaryKey,
        maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
        anchorResolver: AnchorResolver(rootKey: boundaryKey),
        pixelRatio: 1,
        frameWaiter: () => Future<void>.value(),
        encoder: InlineScreenshotEncoder(),
      );
      addTearDown(capturer.dispose);
      await tester.pumpWidget(_scene(boundaryKey, Colors.red));

      final first = await tester.runAsync(
        () => capturer.captureAttempt(force: true),
      );
      expect(first, isNotNull);
      expect(first!.failure, isNull);
      expect(first.result, isNotNull);
      expect(first.result!.skippedByPaintGeneration, isFalse);
      capturer.commitAcceptedPaintGeneration(first.result!.paintGeneration);

      final skipped = await capturer.captureAttempt();
      expect(skipped.failure, isNull);
      expect(skipped.result, isNotNull);
      expect(skipped.result!.skippedByPaintGeneration, isTrue);
      expect(skipped.result!.bytes, isEmpty);

      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as TugboatCaptureRenderBoundary;
      final generationBeforeRepaint = boundary.paintGeneration;
      boundary.markNeedsPaint();
      await tester.pump();
      expect(boundary.paintGeneration, greaterThan(generationBeforeRepaint));

      final afterRepaint = await tester.runAsync(
        () => capturer.captureAttempt(),
      );
      expect(afterRepaint, isNotNull);
      expect(afterRepaint!.failure, isNull);
      expect(afterRepaint.result, isNotNull);
      expect(afterRepaint.result!.skippedByPaintGeneration, isFalse);

      capturer.commitAcceptedPaintGeneration(
        afterRepaint.result!.paintGeneration,
      );
      final forced = await tester.runAsync(
        () => capturer.captureAttempt(force: true),
      );
      expect(forced, isNotNull);
      expect(forced!.failure, isNull);
      expect(forced.result, isNotNull);
      expect(forced.result!.skippedByPaintGeneration, isFalse);
      expect(forced.result!.bytes, isNotEmpty);
    },
  );

  testWidgets(
    'paint-generation gate does not skip when a nested RepaintBoundary paints',
    (tester) async {
      final boundaryKey = GlobalKey();
      var nestedColor = Colors.red;
      final capturer = ScreenshotCapturer(
        boundaryKey: boundaryKey,
        maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
        anchorResolver: AnchorResolver(rootKey: boundaryKey),
        pixelRatio: 1,
        frameWaiter: () => Future<void>.value(),
        encoder: InlineScreenshotEncoder(),
      );
      addTearDown(capturer.dispose);

      Widget scene() => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: TugboatCaptureBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 80,
              height: 80,
              child: RepaintBoundary(child: ColoredBox(color: nestedColor)),
            ),
          ),
        ),
      );

      await tester.pumpWidget(scene());
      final first = await tester.runAsync(
        () => capturer.captureAttempt(force: true),
      );
      expect(first, isNotNull);
      expect(first!.failure, isNull);
      expect(first.result, isNotNull);
      capturer.commitAcceptedPaintGeneration(first.result!.paintGeneration);

      final outer =
          boundaryKey.currentContext!.findRenderObject()!
              as TugboatCaptureRenderBoundary;
      final outerGeneration = outer.paintGeneration;
      final signatureBefore = tugboatSubtreePaintSignature(outer);

      nestedColor = Colors.blue;
      await tester.pumpWidget(scene());
      // Nested boundary owns the paint; outer generation must stay put so this
      // exercises the unsafe outer-only gate scenario.
      expect(outer.paintGeneration, outerGeneration);
      expect(tugboatSubtreePaintSignature(outer), isNot(signatureBefore));

      final afterNested = await tester.runAsync(
        () => capturer.captureAttempt(),
      );
      expect(afterNested, isNotNull);
      expect(afterNested!.failure, isNull);
      expect(afterNested.result, isNotNull);
      expect(afterNested.result!.skippedByPaintGeneration, isFalse);
    },
  );

  testWidgets('capture dimensions respect caps and degraded scaling', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      pixelRatio: 1,
      maxWidth: 40,
      maxHeight: 60,
      degradedScale: 0.5,
      frameWaiter: () => Future<void>.value(),
      encoder: InlineScreenshotEncoder(),
    );
    addTearDown(capturer.dispose);
    await tester.pumpWidget(_scene(boundaryKey, Colors.red));

    final regular = await tester.runAsync(
      () => capturer.captureAttempt(force: true),
    );
    final degraded = await tester.runAsync(
      () => capturer.captureAttempt(force: true, degraded: true),
    );

    expect(regular, isNotNull);
    expect(regular!.result, isNotNull);
    expect(regular.result!.width, 40);
    expect(regular.result!.height, 40);
    expect(degraded, isNotNull);
    expect(degraded!.result, isNotNull);
    expect(degraded.result!.width, 20);
    expect(degraded.result!.height, 20);
  });

  testWidgets('capture preserves public pixel ratios above one', (
    tester,
  ) async {
    const config = TugboatReplayConfig(capturePixelRatio: 2);
    final boundaryKey = GlobalKey();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      pixelRatio: config.capturePixelRatio,
      frameWaiter: () => Future<void>.value(),
      encoder: InlineScreenshotEncoder(),
    );
    addTearDown(capturer.dispose);
    await tester.pumpWidget(_scene(boundaryKey, Colors.red));

    final capture = await tester.runAsync(
      () => capturer.captureAttempt(force: true),
    );

    expect(capture, isNotNull);
    expect(capture!.result, isNotNull);
    expect(capture.result!.width, 160);
    expect(capture.result!.height, 160);
  });

  testWidgets('default degraded scale retains more screenshot detail', (
    tester,
  ) async {
    const config = TugboatReplayConfig();
    final boundaryKey = GlobalKey();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      pixelRatio: config.capturePixelRatio,
      degradedScale: config.degradedCaptureScale,
      frameWaiter: () => Future<void>.value(),
      encoder: InlineScreenshotEncoder(),
    );
    addTearDown(capturer.dispose);
    await tester.pumpWidget(_scene(boundaryKey, Colors.red));

    final degraded = await tester.runAsync(
      () => capturer.captureAttempt(force: true, degraded: true),
    );

    expect(degraded, isNotNull);
    expect(degraded!.result, isNotNull);
    expect(degraded.result!.width, 48);
    expect(degraded.result!.height, 48);
  });

  test('copyWith can clear screenshot dimension bounds', () {
    const bounded = TugboatReplayConfig(
      captureMaxWidth: 540,
      captureMaxHeight: 1080,
    );
    final unbounded = bounded.copyWith(
      clearCaptureMaxWidth: true,
      clearCaptureMaxHeight: true,
    );

    expect(unbounded.captureMaxWidth, isNull);
    expect(unbounded.captureMaxHeight, isNull);
  });

  test('screenshot budget reports independent capture-stage metrics', () {
    final tracker = TugboatScreenshotBudgetTracker();
    tracker.record(
      queueWaitMicros: 11,
      frameWaitMicros: 22,
      readbackMicros: 33,
      maskMicros: 44,
      encodeMicros: 55,
      encodedBytes: 66,
    );

    final snapshot = tracker.snapshot();
    expect(snapshot.avgQueueWaitMicros, 11);
    expect(snapshot.avgFrameWaitMicros, 22);
    expect(snapshot.avgReadbackMicros, 33);
    expect(snapshot.avgMaskMicros, 44);
    expect(snapshot.avgEncodeMicros, 55);
  });
}
