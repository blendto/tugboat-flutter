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
