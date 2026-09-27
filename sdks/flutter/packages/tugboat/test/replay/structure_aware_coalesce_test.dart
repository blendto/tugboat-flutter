import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/capture_boundary.dart';
import 'package:tugboat/src/screenshot_encode.dart';
import 'package:tugboat/tugboat.dart';

// A 9x8 grid whose cells line up exactly with the dHash sample cells at
// pixel ratio 1, so each brightened cell flips exactly one dHash bit (the
// comparison with its left neighbour) and leaves the widget tree unchanged.
const _cellSize = 20.0;
const _columns = 9;
const _rows = 8;
const _base = Color(0xff646464);
const _bright = Color(0xff6e6e6e);

const _config = TugboatReplayConfig(
  enabled: true,
  emitCaptureDiagnostics: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
  // Test readback is slow; keep the rolling budget from skipping captures.
  screenshotBudget: TugboatScreenshotBudgetConfig(
    skipEligibleWhenDegraded: false,
  ),
);

Widget _grid(
  GlobalKey boundaryKey, {
  Set<int> brightRows = const {},
  bool emptyText = false,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: TugboatCaptureBoundary(
        key: boundaryKey,
        child: SizedBox(
          width: _cellSize * _columns,
          height: _cellSize * _rows,
          child: Stack(
            children: [
              Column(
                children: [
                  for (var row = 0; row < _rows; row++)
                    Row(
                      children: [
                        for (var column = 0; column < _columns; column++)
                          SizedBox.square(
                            dimension: _cellSize,
                            child: ColoredBox(
                              color: column == 1 && brightRows.contains(row)
                                  ? _bright
                                  : _base,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
              // An empty paragraph changes the visible structure (a new text
              // box) without painting a single pixel.
              if (emptyText) const Text(''),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<Map<String, Object?>> _resolve(
  WidgetTester tester,
  Future<Map<String, Object?>> future,
) async {
  final resolution = Completer<Map<String, Object?>>();
  unawaited(
    future.then(resolution.complete, onError: resolution.completeError),
  );
  for (var attempt = 0; attempt < 80; attempt++) {
    if (resolution.isCompleted) return resolution.future;
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(resolution.isCompleted, isTrue, reason: 'capture did not resolve');
  return resolution.future;
}

Future<TugboatReplayController> _startWithBaseline(
  WidgetTester tester,
  GlobalKey boundaryKey,
) async {
  await tester.pumpWidget(_grid(boundaryKey));
  final controller = TugboatReplayController(
    config: _config,
    boundaryKey: boundaryKey,
  )..debugScreenshotEncoder = InlineScreenshotEncoder();
  addTearDown(controller.dispose);
  await controller.initialize();
  controller.start(const Size(_cellSize * _columns, _cellSize * _rows), 'test');
  final baseline = await _resolve(
    tester,
    controller.debugRequestCapture(force: true).resolution,
  );
  expect(baseline['outcome'], 'fresh_accepted');
  return controller;
}

Future<Map<String, Object?>> _captureReusable(
  WidgetTester tester,
  TugboatReplayController controller,
) => _resolve(tester, controller.debugRequestCapture().resolution);

void main() {
  test('control state distinguishes toggle value and enabled state', () {
    void onChanged(bool? _) {}
    final on = tugboatControlStateSignature(
      Checkbox(value: true, onChanged: onChanged),
    );
    final off = tugboatControlStateSignature(
      Checkbox(value: false, onChanged: onChanged),
    );
    const disabled = Checkbox(value: true, onChanged: null);
    expect(on, isNotNull);
    expect(on, isNot(off));
    expect(on, isNot(tugboatControlStateSignature(disabled)));
    expect(
      on,
      tugboatControlStateSignature(Checkbox(value: true, onChanged: onChanged)),
    );
    expect(
      tugboatControlStateSignature(Switch(value: true, onChanged: onChanged)),
      isNot(
        tugboatControlStateSignature(
          Switch(value: false, onChanged: onChanged),
        ),
      ),
    );
    expect(tugboatControlStateSignature(const Text('not a control')), isNull);
    void onSelected(bool _) {}
    expect(
      tugboatControlStateSignature(
        FilterChip(
          label: const Text('a'),
          selected: true,
          onSelected: onSelected,
        ),
      ),
      isNot(
        tugboatControlStateSignature(
          FilterChip(
            label: const Text('a'),
            selected: false,
            onSelected: onSelected,
          ),
        ),
      ),
    );
    void onSlide(double _) {}
    expect(
      tugboatControlStateSignature(Slider(value: 0.2, onChanged: onSlide)),
      isNot(
        tugboatControlStateSignature(Slider(value: 0.8, onChanged: onSlide)),
      ),
    );
  });

  testWidgets('structure changes when a RadioGroup selection moves', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    Widget radios(int selected) => MaterialApp(
      home: TugboatCaptureBoundary(
        key: boundaryKey,
        child: Material(
          child: RadioGroup<int>(
            groupValue: selected,
            onChanged: (_) {},
            child: const Column(
              children: [Radio<int>(value: 1), Radio<int>(value: 2)],
            ),
          ),
        ),
      ),
    );
    final resolver = AnchorResolver(rootKey: boundaryKey);
    int? signature() {
      resolver.invalidateTokenMapCache();
      return resolver.structureSignature(
        rootRender:
            boundaryKey.currentContext!.findRenderObject()! as RenderBox,
      );
    }

    await tester.pumpWidget(radios(1));
    await tester.pumpAndSettle();
    final first = signature();
    expect(first, isNotNull);
    expect(signature(), first, reason: 'stable for an unchanged tree');

    await tester.pumpWidget(radios(2));
    await tester.pumpAndSettle();
    expect(signature(), isNot(first));
  });

  testWidgets(
    'a one-bit change with an unchanged tree still coalesces perceptually',
    (tester) async {
      final boundaryKey = GlobalKey();
      final controller = await _startWithBaseline(tester, boundaryKey);
      final frames = controller.session!.frames.length;

      await tester.pumpWidget(_grid(boundaryKey, brightRows: {0}));
      final result = await _captureReusable(tester, controller);

      expect(result['outcome'], 'perceptual_hash_coalesced');
      expect(controller.session!.frames, hasLength(frames));
    },
  );

  testWidgets(
    'the same one-bit change is encoded when the visible structure changed',
    (tester) async {
      final boundaryKey = GlobalKey();
      final controller = await _startWithBaseline(tester, boundaryKey);
      final frames = controller.session!.frames.length;

      await tester.pumpWidget(
        _grid(boundaryKey, brightRows: {0}, emptyText: true),
      );
      final result = await _captureReusable(tester, controller);

      expect(result['outcome'], 'fresh_accepted');
      expect(controller.session!.frames, hasLength(frames + 1));
    },
  );

  testWidgets(
    'identical pixels under a changed tree reuse exact content, not dHash',
    (tester) async {
      final boundaryKey = GlobalKey();
      final controller = await _startWithBaseline(tester, boundaryKey);
      final frames = controller.session!.frames.length;

      await tester.pumpWidget(_grid(boundaryKey, emptyText: true));
      final result = await _captureReusable(tester, controller);

      expect(result['outcome'], 'exact_content_reused');
      expect(controller.session!.frames, hasLength(frames));
    },
  );

  testWidgets(
    'perceptual coalescing never advances the baseline past the referenced '
    'frame',
    (tester) async {
      final boundaryKey = GlobalKey();
      final controller = await _startWithBaseline(tester, boundaryKey);
      final baselineFrames = controller.session!.frames.length;

      // Each step is one bit away from the previous one. Only the distance
      // to the frame that is actually referenced may decide coalescing.
      await tester.pumpWidget(_grid(boundaryKey, brightRows: {0}));
      final oneBit = await _captureReusable(tester, controller);
      await tester.pumpWidget(_grid(boundaryKey, brightRows: {0, 1}));
      final twoBits = await _captureReusable(tester, controller);
      await tester.pumpWidget(_grid(boundaryKey, brightRows: {0, 1, 2}));
      final threeBits = await _captureReusable(tester, controller);

      expect(oneBit['outcome'], 'perceptual_hash_coalesced');
      expect(twoBits['outcome'], 'perceptual_hash_coalesced');
      expect(threeBits['outcome'], 'fresh_accepted');
      expect(controller.session!.frames, hasLength(baselineFrames + 1));
    },
  );
}
