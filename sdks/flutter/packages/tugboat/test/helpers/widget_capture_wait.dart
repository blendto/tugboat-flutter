import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

/// Drives Flutter frames and asynchronous encoding until Tugboat is idle.
Future<void> waitForTugboatCaptureWork(WidgetTester tester) async {
  var consecutiveIdleChecks = 0;
  for (var attempt = 0; attempt < 500; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );

    final controller = TugboatReplay.controller;
    final idle =
        controller != null &&
        !controller.debugCaptureInFlight &&
        !controller.debugRouteCapturePending &&
        controller.debugActiveTapSettleCount == 0 &&
        controller.debugScheduledCaptureRoutes.isEmpty;
    consecutiveIdleChecks = idle ? consecutiveIdleChecks + 1 : 0;
    if (consecutiveIdleChecks >= 2) return;
  }

  final controller = TugboatReplay.controller;
  fail(
    'Tugboat capture work did not become idle: '
    'controller=${controller != null}, '
    'captureInFlight=${controller?.debugCaptureInFlight}, '
    'routeCapturePending=${controller?.debugRouteCapturePending}, '
    'activeTapSettles=${controller?.debugActiveTapSettleCount}, '
    'scheduledRoutes=${controller?.debugScheduledCaptureRoutes}',
  );
}

/// Gives real asynchronous capture work (encoding, isolate round trips) up to
/// [maxWait] of wall-clock time to finish, returning as soon as no capture is
/// in flight or pending on two consecutive checks.
///
/// Unlike [waitForTugboatCaptureWork] this never advances the fake clock, so
/// timers the test has not pumped past stay unfired, and it never fails: at
/// worst it waits as long as the fixed sleep it replaces.
Future<void> settleTugboatCaptureWork(
  WidgetTester tester, {
  Duration maxWait = const Duration(milliseconds: 400),
}) async {
  const step = Duration(milliseconds: 10);
  final clock = Stopwatch()..start();
  var consecutiveIdleChecks = 0;
  await tester.pump();
  while (clock.elapsed < maxWait) {
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump();
    final controller = TugboatReplay.controller;
    final idle =
        controller == null ||
        (!controller.debugCaptureInFlight &&
            !controller.debugRouteCapturePending);
    consecutiveIdleChecks = idle ? consecutiveIdleChecks + 1 : 0;
    if (consecutiveIdleChecks >= 2) return;
  }
}
