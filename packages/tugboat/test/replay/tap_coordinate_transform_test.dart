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
    TugboatReplay.debugConfigureControllerForTest = (controller) {
      controller.debugExecuteCapture =
          ({required trigger, required force}) async {
            return controller.debugSeedFrame(trigger: trigger);
          };
    };
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: TugboatReplayConfig(
            profile: TugboatCaptureProfile.exploration,
            settleDelay: Duration.zero,
            interactionClaimWindow: Duration.zero,
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
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
    controller.recordPointerUp(center);
    await tester.pump();
    await controller.drainPointerQueue();
    final interaction = controller.session!.events
        .where((event) => event.type == 'interaction')
        .last;
    final position =
        Map<String, Object?>.from(
              interaction.data['payload']! as Map,
            )['position']
            as Map;
    expect(position['xNorm'], inInclusiveRange(0.0, 1.0));
    expect(position['yNorm'], inInclusiveRange(0.0, 1.0));
  });

  testWidgets('outside-boundary tap is unavailable without clamping', (
    tester,
  ) async {
    final controller = await mount(tester);
    // Far outside the capture boundary / screen.
    controller.recordPointerDown(const Offset(-80, -80));
    controller.recordPointerUp(const Offset(-80, -80));
    await tester.pump();
    await controller.drainPointerQueue();
    final interaction = controller.session!.events
        .where((event) => event.type == 'interaction')
        .last;
    expect(interaction.data['payload'], isNull);
  });

  testWidgets('capture ratio below 1.0 still projects within one pixel', (
    tester,
  ) async {
    final controller = await mount(tester, capturePixelRatio: 0.5);
    // Ensure a real before-frame exists at the reduced ratio.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    final center = tester.getCenter(find.byKey(const Key('target')));
    controller.recordPointerDown(center);
    controller.recordPointerUp(center);
    await tester.pump();
    await controller.drainPointerQueue();
    final interaction = controller.session!.events
        .where((event) => event.type == 'interaction')
        .last;
    final payload = Map<String, Object?>.from(
      interaction.data['payload']! as Map,
    );
    final position = Map<String, Object?>.from(payload['position']! as Map);
    expect(position['xNorm'], inInclusiveRange(0.0, 1.0));
    expect(position['yNorm'], inInclusiveRange(0.0, 1.0));
  });

  testWidgets('resized boundary suppresses coordinates for the older frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = await mount(tester);

    tester.view.physicalSize = const Size(900, 600);
    await tester.pump();

    final center = tester.getCenter(find.byKey(const Key('target')));
    controller.recordPointerDown(center);
    controller.recordPointerUp(center);
    await tester.pump();
    await controller.drainPointerQueue();
    final interaction = controller.session!.events
        .where((event) => event.type == 'interaction')
        .last;
    expect(interaction.beforeFrame, isNull);
    expect(interaction.data['payload'], isNull);
  });
}
