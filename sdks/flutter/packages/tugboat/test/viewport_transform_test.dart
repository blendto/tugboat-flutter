import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// The documented conversion, `(boundaryOffset + boundsNorm * widthPx) *
// devicePixelRatio`, must give device pixels of the Flutter view for a
// boundary under any scale. A host app scales its whole UI by 1.0549
// with a binding that sets the RenderView's ViewConfiguration ratio to
// view.devicePixelRatio * scale (720 px / (1.75 * 1.0549) = 390 logical px).
// The SDK reported the view's 1.75, so every box was 19-72 px off on device.

const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

Widget _page() => Scaffold(
  body: Center(
    child: FilledButton(onPressed: () {}, child: const Text('Action')),
  ),
);

Future<Map<String, Object?>> _viewport(
  WidgetTester tester,
  Widget Function(Widget boundary) around,
) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          around(TugboatReplay.wrapApp(config: _exploration, child: child!)),
      home: _page(),
    ),
  );
  await waitForTugboatCaptureWork(tester);
  final inventory = TugboatReplay.controller!.session!.events.lastWhere(
    (e) => e.type == 'scene_inventory',
  );
  return (inventory.data['viewport']! as Map).cast<String, Object?>();
}

/// Device pixels of the boundary-normalized point [norm] by the doc formula.
Offset _formula(Map<String, Object?> viewport, Offset norm) {
  final offset = (viewport['boundaryOffset']! as Map).cast<String, double>();
  final ratio = viewport['devicePixelRatio']! as double;
  return Offset(
    (offset['left']! + norm.dx * (viewport['widthPx']! as double)) * ratio,
    (offset['top']! + norm.dy * (viewport['heightPx']! as double)) * ratio,
  );
}

void _view(WidgetTester tester, {required Size physical, required double dpr}) {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = dpr;
  tester.view.viewPadding = const FakeViewPadding(top: 70);
  addTearDown(tester.view.reset);
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a boundary under Transform.scale reports its scaled box', (
    tester,
  ) async {
    _view(tester, physical: const Size(800, 1200), dpr: 2);
    final viewport = await _viewport(
      tester,
      (boundary) => Transform.scale(
        scale: 0.5,
        alignment: Alignment.topLeft,
        child: boundary,
      ),
    );

    expect(viewport['widthPx'], 200.0);
    expect(viewport['heightPx'], 300.0);
    expect(viewport['boundaryOffset'], {'left': 0.0, 'top': 0.0});
    expect(viewport['devicePixelRatio'], 2.0);
    // The boundary's bottom-right corner lands on the middle of the screen.
    expect(_formula(viewport, const Offset(1, 1)), const Offset(400, 600));
  });

  testWidgets('a boundary in a FittedBox reports its fitted box', (
    tester,
  ) async {
    _view(tester, physical: const Size(800, 1200), dpr: 1);
    final viewport = await _viewport(
      tester,
      (boundary) => Center(
        child: SizedBox(
          width: 300,
          height: 300,
          child: FittedBox(
            child: SizedBox(width: 600, height: 600, child: boundary),
          ),
        ),
      ),
    );

    expect(viewport['widthPx'], 300.0);
    expect(viewport['heightPx'], 300.0);
    expect(viewport['boundaryOffset'], {'left': 250.0, 'top': 450.0});
    expect(_formula(viewport, Offset.zero), const Offset(250, 450));
    expect(_formula(viewport, const Offset(1, 1)), const Offset(550, 750));
  });

  testWidgets('a binding that scales the render view reports its ratio', (
    tester,
  ) async {
    // The host: 720x1560 px at 1.75, scaled by 411.43 / 390.
    _view(tester, physical: const Size(720, 1560), dpr: 1.75);
    const scaled = 1.75 * (720 / 1.75 / 390);
    final renderView = tester.binding.renderViews.single;
    final unscaled = renderView.configuration;
    final constraints = BoxConstraints.tight(const Size(720, 1560));
    void scale() => renderView.configuration = ViewConfiguration(
      physicalConstraints: constraints,
      logicalConstraints: constraints / scaled,
      devicePixelRatio: scaled,
    );
    addTearDown(() => renderView.configuration = unscaled);
    scale();
    final viewport = await _viewport(tester, (boundary) => boundary);

    expect(viewport['widthPx'], closeTo(390, 1e-9));
    expect(viewport['heightPx'], closeTo(1560 / scaled, 1e-9));
    expect(viewport['devicePixelRatio'], closeTo(scaled, 1e-12));
    // The full boundary is the full 720x1560 px screen.
    final corner = _formula(viewport, const Offset(1, 1));
    expect(corner.dx, closeTo(720, 1e-6));
    expect(corner.dy, closeTo(1560, 1e-6));
    // 70 px of status bar, in the same logical pixels as the boxes.
    final insets = (viewport['insets']! as Map).cast<String, double>();
    expect(insets['top']! * scaled, closeTo(70, 1e-9));
  });
}
