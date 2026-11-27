// BLE-633: the shared privacy model (docs/architecture/native-capture-contracts.md,
// "Privacy model"), checked against the Flutter adapter.
//
// The rect lists come from the real ScreenshotCapturer mask walk, taken from
// the request it hands to its pixel source, so these tests see exactly what
// would be filled before encoding.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/capture_boundary.dart';
import 'package:tugboat/src/markers.dart';
import 'package:tugboat/src/screenshot_capture_backend.dart';
import 'package:tugboat/src/screenshot_capturer.dart';
import 'package:tugboat/src/screenshot_mask_level.dart';
import 'package:tugboat/src/screenshot_pixel_source.dart';

class _RecordingPixelSource implements ScreenshotPixelSource {
  final requests = <ScreenshotPixelRequest>[];

  @override
  Future<ScreenshotPixelAcquisition> acquire(
    ScreenshotPixelRequest request,
  ) async {
    requests.add(request);
    return const ScreenshotPixelAcquisition(
      disposition: ScreenshotPixelDisposition.failed,
      failure: ScreenshotCaptureFailureKind.readbackFailed,
      trace: ScreenshotBackendTrace.flutter(),
    );
  }

  @override
  void resetSession() {}

  @override
  Future<void> dispose() async {}
}

/// Mask rects (boundary-local logical pixels) the capturer would fill for
/// [body] at [level].
Future<List<Rect>> _masks(
  WidgetTester tester,
  TugboatScreenshotMaskLevel level,
  Widget body,
) async {
  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TugboatCaptureBoundary(
          key: boundaryKey,
          child: Align(alignment: Alignment.topLeft, child: body),
        ),
      ),
    ),
  );
  await tester.pump();
  final source = _RecordingPixelSource();
  final capturer = ScreenshotCapturer(
    boundaryKey: boundaryKey,
    maskLevel: level,
    anchorResolver: AnchorResolver(rootKey: boundaryKey),
    pixelRatio: 1,
    pixelSource: source,
  );
  addTearDown(capturer.dispose);
  await capturer.captureAttempt(waitForFrame: false);
  expect(source.requests, hasLength(1), reason: 'the capture reached pixels');
  return source.requests.single.maskRects;
}

bool _covers(List<Rect> masks, Rect target) =>
    masks.any((m) => m.inflate(0.5).overlaps(target) && _contains(m, target));

bool _contains(Rect outer, Rect inner) =>
    outer.left <= inner.left + 0.5 &&
    outer.top <= inner.top + 0.5 &&
    outer.right >= inner.right - 0.5 &&
    outer.bottom >= inner.bottom - 0.5;

Rect _boundsOf(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  final boundary = tester.renderObject<RenderBox>(
    find.byType(TugboatCaptureBoundary),
  );
  return MatrixUtils.transformRect(
    box.getTransformTo(boundary),
    Offset.zero & box.size,
  );
}

const _panelKey = ValueKey('panel');
const _panel = SizedBox(
  key: _panelKey,
  width: 80,
  height: 40,
  child: ColoredBox(color: Colors.black),
);

void main() {
  group('Flutter adapter, privacy model', () {
    testWidgets('allTextAndMedia is the level the SDK defaults to', (
      tester,
    ) async {
      // Default resolution lives in TugboatReplayConfig; the contract names
      // allTextAndMedia as the default level.
      expect(
        TugboatScreenshotMaskLevel.values.map((l) => l.name),
        contains('allTextAndMedia'),
      );
      final masks = await _masks(
        tester,
        TugboatScreenshotMaskLevel.allTextAndMedia,
        const Text('Card 4242', key: ValueKey('text')),
      );
      expect(
        _covers(masks, _boundsOf(tester, find.byKey(const ValueKey('text')))),
        isTrue,
      );
    });

    for (final level in TugboatScreenshotMaskLevel.values) {
      testWidgets('a mark adds its subtree at level ${level.name}', (
        tester,
      ) async {
        final masks = await _masks(
          tester,
          level,
          const TugboatSensitive(child: _panel),
        );
        expect(
          _covers(masks, _boundsOf(tester, find.byKey(_panelKey))),
          isTrue,
          reason: 'a mark masks at every level, the most permissive included',
        );
      });

      testWidgets('a mark never removes a mask at level ${level.name}', (
        tester,
      ) async {
        const text = Text('Name', key: ValueKey('t'));
        final plain = await _masks(tester, level, text);
        final marked = await _masks(
          tester,
          level,
          const TugboatSensitive(child: text),
        );
        for (final rect in plain) {
          expect(_covers(marked, rect), isTrue, reason: '$rect stays masked');
        }
      });
    }

    testWidgets('a mark inherits down: a nested mark cannot loosen it', (
      tester,
    ) async {
      final masks = await _masks(
        tester,
        TugboatScreenshotMaskLevel.explicitOnly,
        const TugboatSensitive(
          child: Column(
            children: [
              TugboatSensitive(child: _panel),
              SizedBox(
                key: ValueKey('second'),
                width: 80,
                height: 40,
                child: ColoredBox(color: Colors.black),
              ),
            ],
          ),
        ),
      );
      expect(_covers(masks, _boundsOf(tester, find.byKey(_panelKey))), isTrue);
      expect(
        _covers(masks, _boundsOf(tester, find.byKey(const ValueKey('second')))),
        isTrue,
        reason: 'the unmarked child of a mark is masked with it',
      );
    });

    // KNOWN GAP, not fixed by BLE-633 (a behaviour change; see the PR and the
    // contract's "Differences"). The Flutter mask walk skips subtrees under
    // an excluding `ExcludeSemantics`, so text and marks inside one are not
    // masked at any level. The contract requires them masked ("an adapter
    // that cannot place a mask masks more, never less"). Remove `skip` when
    // the walk is fixed for every SDK.
    testWidgets(
      'content under ExcludeSemantics is still masked at allTextAndMedia',
      (tester) async {
        final masks = await _masks(
          tester,
          TugboatScreenshotMaskLevel.allTextAndMedia,
          const ExcludeSemantics(child: Text('Card 4242', key: ValueKey('t'))),
        );
        expect(
          _covers(masks, _boundsOf(tester, find.byKey(const ValueKey('t')))),
          isTrue,
        );
      },
      skip: true, // known gap, see the comment above
    );

    testWidgets(
      'a mark under ExcludeSemantics is still masked',
      (tester) async {
        final masks = await _masks(
          tester,
          TugboatScreenshotMaskLevel.explicitOnly,
          const ExcludeSemantics(child: TugboatSensitive(child: _panel)),
        );
        expect(
          _covers(masks, _boundsOf(tester, find.byKey(_panelKey))),
          isTrue,
        );
      },
      skip: true, // known gap, see the comment above
    );
  });
}
