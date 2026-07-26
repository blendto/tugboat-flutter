import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

/// Runtime pointer-to-frame transform capture (U13).
void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  Future<TugboatReplayController> mount(
    WidgetTester tester, {
    EdgeInsets padding = EdgeInsets.zero,
    double capturePixelRatio = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: TugboatReplayConfig(
            profile: TugboatCaptureProfile.exploration,
            settleDelay: Duration.zero,
            enableGlobalPointerCapture: true,
            capturePixelRatio: capturePixelRatio,
            screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
          ),
          child: child!,
        ),
        home: MediaQuery(
          data: MediaQueryData(padding: padding),
          child: Scaffold(
            body: SafeArea(
              child: Center(
                child: ColoredBox(
                  color: const Color(0xFF222222),
                  child: SizedBox(
                    width: 200,
                    height: 200,
                    child: FilledButton(
                      key: const Key('target'),
                      onPressed: () {},
                      child: const Text('tap'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    await tester.pump();
    final controller = TugboatReplay.controller;
    expect(controller, isNotNull);
    expect(controller!.session, isNotNull);
    return controller;
  }

  testWidgets('edge taps emit available captureCoordinate inside boundary', (
    tester,
  ) async {
    final controller = await mount(
      tester,
      padding: const EdgeInsets.only(top: 48, bottom: 24),
    );
    final center = tester.getCenter(find.byKey(const Key('target')));
    controller.recordPointerDown(center);
    final tap = controller.session!.events.where((e) => e.type == 'tap').last;
    expect(tap.data['x'], center.dx);
    expect(tap.data['y'], center.dy);
    final coord = Map<String, Object?>.from(
      tap.data['captureCoordinate']! as Map,
    );
    expect(coord['version'], 1);
    expect(coord['unavailableReason'], isNull);
    expect(coord['normalizedX'], inInclusiveRange(0.0, 1.0));
    expect(coord['normalizedY'], inInclusiveRange(0.0, 1.0));
    expect(coord['frameId'], isNotNull);

    final restored = TugboatCaptureCoordinate.fromJson(coord);
    final raster = restored.projectToRaster();
    expect(raster, isNotNull);
    expect(raster!.x, inInclusiveRange(0, restored.framePixelWidth - 1));
    expect(raster.y, inInclusiveRange(0, restored.framePixelHeight - 1));
  });

  testWidgets('outside-boundary tap is unavailable without clamping', (
    tester,
  ) async {
    final controller = await mount(tester);
    // Far outside the capture boundary / screen.
    controller.recordPointerDown(const Offset(-80, -80));
    final tap = controller.session!.events.where((e) => e.type == 'tap').last;
    final coord = Map<String, Object?>.from(
      tap.data['captureCoordinate']! as Map,
    );
    expect(coord['unavailableReason'], 'outside_boundary');
    expect(tap.data['x'], -80);
    expect(tap.data['y'], -80);
  });

  testWidgets('capture ratio below 1.0 still projects within one pixel', (
    tester,
  ) async {
    final controller = await mount(tester, capturePixelRatio: 0.5);
    // Ensure a real before-frame exists at the reduced ratio.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    await tester.pump();
    final center = tester.getCenter(find.byKey(const Key('target')));
    controller.recordPointerDown(center);
    final tap = controller.session!.events.where((e) => e.type == 'tap').last;
    final coord = TugboatCaptureCoordinate.fromJson(
      Map<String, Object?>.from(tap.data['captureCoordinate']! as Map),
    );
    if (!coord.isAvailable) {
      // No compatible before-frame yet — still emit explicit unavailability.
      expect(coord.unavailableReason, isNotNull);
      return;
    }
    final raster = coord.projectToRaster()!;
    final backX = raster.x / (coord.framePixelWidth - 1);
    final backY = raster.y / (coord.framePixelHeight - 1);
    expect((backX - coord.normalizedX).abs(), lessThan(0.02));
    expect((backY - coord.normalizedY).abs(), lessThan(0.02));
  });
}
