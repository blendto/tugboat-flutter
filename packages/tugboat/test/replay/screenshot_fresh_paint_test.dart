import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/capture_boundary.dart';
import 'package:tugboat/src/health.dart';
import 'package:tugboat/src/screenshot_capturer.dart';
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

    await tester.pumpWidget(_scene(boundaryKey, Colors.blue));
    final blueFrame = Completer<void>();
    final blueCapturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      pixelRatio: 1,
      frameWaiter: () => blueFrame.future,
    );
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
