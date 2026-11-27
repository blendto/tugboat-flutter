// BLE-633: the shared privacy model (docs/architecture/native-capture-contracts.md,
// "Privacy model"), checked against the Flutter adapter.
//
// The rect lists come from the real ScreenshotCapturer mask walk, taken from
// the request it hands to its pixel source, so these tests see exactly what
// would be filled before encoding.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/capture_boundary.dart';
import 'package:tugboat/src/markers.dart';
import 'package:tugboat/src/replay_config.dart';
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

/// Masks for an app already pumped inside a [TugboatCaptureBoundary] keyed
/// [boundaryKey] (so overlays, which live in the Navigator, are in the walk).
/// `masks` is null when the capture failed before reaching pixels, and then
/// `failure` says why. [rootKey] is the mask walk's root (default: the
/// boundary).
Future<({List<Rect>? masks, ScreenshotCaptureFailure? failure})> _masksOfApp(
  WidgetTester tester,
  GlobalKey boundaryKey,
  TugboatScreenshotMaskLevel level, {
  GlobalKey? rootKey,
}) async {
  final source = _RecordingPixelSource();
  final capturer = ScreenshotCapturer(
    boundaryKey: boundaryKey,
    maskLevel: level,
    anchorResolver: AnchorResolver(rootKey: rootKey ?? boundaryKey),
    pixelRatio: 1,
    pixelSource: source,
  );
  addTearDown(capturer.dispose);
  final attempt = await capturer.captureAttempt(waitForFrame: false);
  return (
    masks: source.requests.isEmpty ? null : source.requests.single.maskRects,
    failure: attempt.failure,
  );
}

/// A leaf box whose paint bounds cannot be read, so its mask cannot be placed.
class _UnplaceableBox extends LeafRenderObjectWidget {
  const _UnplaceableBox();

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderUnplaceable();
}

class _RenderUnplaceable extends RenderBox {
  @override
  void performLayout() => size = constraints.constrain(const Size(60, 30));

  @override
  Rect get paintBounds => throw StateError('paint bounds unavailable');
}

final _tinyImage = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

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
    test('the six level names are pinned, in order', () {
      expect(TugboatScreenshotMaskLevel.values.map((l) => l.name), [
        'explicitOnly',
        'allTextAndMedia',
        'allText',
        'allTextExceptActionable',
        'sensitiveInputsOnly',
        'nonAssetImagesOnly',
      ]);
    });

    test('allTextAndMedia is the default level', () {
      expect(
        const TugboatReplayConfig().effectiveScreenshotMaskLevel,
        TugboatScreenshotMaskLevel.allTextAndMedia,
      );
    });

    testWidgets('allTextAndMedia masks text', (tester) async {
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
        // Content every level except explicitOnly masks in part: a secure
        // input, text, and a non-asset image.
        final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 120,
              child: TextField(obscureText: true, key: ValueKey('pw')),
            ),
            const Text('Name', key: ValueKey('t')),
            Image.memory(_tinyImage, key: const ValueKey('img'), width: 20),
          ],
        );
        final plain = await _masks(tester, level, content);
        if (level != TugboatScreenshotMaskLevel.explicitOnly) {
          expect(plain, isNotEmpty, reason: 'the baseline is not vacuous');
        }
        final marked = await _masks(
          tester,
          level,
          TugboatSensitive(child: content),
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

    // KNOWN GAPS, not fixed by BLE-633 (behaviour changes; see the contract's
    // Differences and BLE-679). Each test states what the contract requires:
    // content the walk cannot place is masked, never left visible. Remove
    // `skip` when the walk is fixed for every SDK.
    const gap = true; // skip: known gap, BLE-679

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
      skip: gap, // BLE-679
    );

    testWidgets(
      'Text(semanticsLabel:) is masked: Flutter adds ExcludeSemantics itself',
      (tester) async {
        final masks = await _masks(
          tester,
          TugboatScreenshotMaskLevel.allTextAndMedia,
          const Text('4242', semanticsLabel: 'card', key: ValueKey('t')),
        );
        expect(
          _covers(masks, _boundsOf(tester, find.byKey(const ValueKey('t')))),
          isTrue,
        );
      },
      skip: gap, // BLE-679
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
      skip: gap, // BLE-679
    );

    testWidgets(
      'a mark above an excluded subtree masks it',
      (tester) async {
        final masks = await _masks(
          tester,
          TugboatScreenshotMaskLevel.explicitOnly,
          const TugboatSensitive(child: ExcludeSemantics(child: _panel)),
        );
        expect(
          _covers(masks, _boundsOf(tester, find.byKey(_panelKey))),
          isTrue,
        );
      },
      skip: gap, // BLE-679
    );

    testWidgets(
      'TugboatInternal does not suppress masks below it',
      (tester) async {
        final masks = await _masks(
          tester,
          TugboatScreenshotMaskLevel.allTextAndMedia,
          const TugboatInternal(child: Text('4242', key: ValueKey('t'))),
        );
        expect(
          _covers(masks, _boundsOf(tester, find.byKey(const ValueKey('t')))),
          isTrue,
        );
      },
      skip: gap, // BLE-679
    );

    testWidgets(
      'a render object whose mask cannot be placed fails closed',
      (tester) async {
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          TugboatCaptureBoundary(
            key: boundaryKey,
            child: const Directionality(
              textDirection: TextDirection.ltr,
              child: TugboatSensitive(child: _UnplaceableBox()),
            ),
          ),
        );
        final result = await _masksOfApp(
          tester,
          boundaryKey,
          TugboatScreenshotMaskLevel.explicitOnly,
        );
        // The capture fails with maskFailed (no frame), or the whole boundary
        // is masked. Any other failure, or a dropped mask, is a leak.
        final boundary = tester.renderObject<RenderBox>(
          find.byType(TugboatCaptureBoundary),
        );
        final masks = result.masks;
        expect(
          masks == null
              ? result.failure == ScreenshotCaptureFailure.maskFailed
              : _covers(masks, Offset.zero & boundary.size),
          isTrue,
          reason: 'an unplaceable mask must not be dropped',
        );
      },
      skip: gap, // BLE-679
    );

    testWidgets(
      'a walk with no root does not return an unmasked frame',
      (tester) async {
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          TugboatCaptureBoundary(
            key: boundaryKey,
            child: const Directionality(
              textDirection: TextDirection.ltr,
              child: Text('4242'),
            ),
          ),
        );
        // The walk's root is a key nothing is mounted under.
        final result = await _masksOfApp(
          tester,
          boundaryKey,
          TugboatScreenshotMaskLevel.allTextAndMedia,
          rootKey: GlobalKey(),
        );
        final boundary = tester.renderObject<RenderBox>(
          find.byType(TugboatCaptureBoundary),
        );
        final masks = result.masks;
        expect(
          masks == null
              ? result.failure == ScreenshotCaptureFailure.maskFailed
              : _covers(masks, Offset.zero & boundary.size),
          isTrue,
        );
      },
      skip: gap, // BLE-679
    );

    testWidgets(
      'Icon(semanticLabel:) is masked: Flutter adds ExcludeSemantics itself',
      (tester) async {
        final masks = await _masks(
          tester,
          TugboatScreenshotMaskLevel.allTextAndMedia,
          const Icon(Icons.lock, semanticLabel: 'lock', key: ValueKey('i')),
        );
        expect(
          _covers(masks, _boundsOf(tester, find.byKey(const ValueKey('i')))),
          isTrue,
        );
      },
      skip: gap, // BLE-679
    );

    testWidgets(
      'the outgoing child of an AnimatedCrossFade is masked',
      (tester) async {
        Widget fade(CrossFadeState state) => AnimatedCrossFade(
          duration: const Duration(milliseconds: 400),
          crossFadeState: state,
          firstChild: const Text('4242', key: ValueKey('first')),
          secondChild: const Text('other', key: ValueKey('second')),
        );
        final boundaryKey = GlobalKey();
        Widget app(CrossFadeState state) => TugboatCaptureBoundary(
          key: boundaryKey,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(alignment: Alignment.topLeft, child: fade(state)),
          ),
        );
        await tester.pumpWidget(app(CrossFadeState.showFirst));
        await tester.pumpWidget(app(CrossFadeState.showSecond));
        await tester.pump(const Duration(milliseconds: 200));
        final masks = (await _masksOfApp(
          tester,
          boundaryKey,
          TugboatScreenshotMaskLevel.allTextAndMedia,
        )).masks;
        expect(masks, isNotNull);
        expect(
          _covers(
            masks!,
            _boundsOf(tester, find.byKey(const ValueKey('first'))),
          ),
          isTrue,
          reason: 'the outgoing child is still painted',
        );
      },
      skip: gap, // BLE-679
    );

    // Guards the overlay rule today: a drawer is an overlay route, and
    // content behind it must stay masked. Not skipped.
    testWidgets('content behind an open drawer stays masked', (tester) async {
      final boundaryKey = GlobalKey();
      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        TugboatCaptureBoundary(
          key: boundaryKey,
          child: MaterialApp(
            home: Scaffold(
              key: scaffoldKey,
              drawer: const Drawer(child: Text('drawer item')),
              body: const Column(
                children: [
                  Text('Balance 4242.00', key: ValueKey('bgText')),
                  TugboatSensitive(
                    child: SizedBox(
                      key: ValueKey('bgSensitive'),
                      width: 80,
                      height: 40,
                      child: ColoredBox(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
      final masks = (await _masksOfApp(
        tester,
        boundaryKey,
        TugboatScreenshotMaskLevel.allTextAndMedia,
      )).masks;
      expect(masks, isNotNull);
      for (final key in ['bgText', 'bgSensitive']) {
        expect(
          _covers(masks!, _boundsOf(tester, find.byKey(ValueKey(key)))),
          isTrue,
          reason: '$key behind the drawer',
        );
      }
    });

    group('content behind a modal surface is still painted, so masked', () {
      final boundaryKey = GlobalKey();

      Widget app() => TugboatCaptureBoundary(
        key: boundaryKey,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Text('Balance 4242.00', key: ValueKey('bgText')),
                const TugboatSensitive(
                  child: SizedBox(
                    key: ValueKey('bgSensitive'),
                    width: 80,
                    height: 40,
                    child: ColoredBox(color: Colors.red),
                  ),
                ),
                PopupMenuButton<int>(
                  key: const ValueKey('popup'),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 1, child: Text('menu item')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );

      Future<void> expectBackgroundMasked(WidgetTester tester) async {
        final masks = (await _masksOfApp(
          tester,
          boundaryKey,
          TugboatScreenshotMaskLevel.allTextAndMedia,
        )).masks;
        expect(masks, isNotNull);
        for (final key in ['bgText', 'bgSensitive']) {
          expect(
            _covers(
              masks!,
              _boundsOf(tester, find.byKey(ValueKey(key), skipOffstage: false)),
            ),
            isTrue,
            reason: '$key behind the overlay',
          );
        }
      }

      testWidgets('an open dialog', (tester) async {
        await tester.pumpWidget(app());
        showDialog<void>(
          context: tester.element(find.byKey(const ValueKey('bgText'))),
          builder: (_) => const AlertDialog(title: Text('Confirm')),
        );
        await tester.pumpAndSettle();
        await expectBackgroundMasked(tester);
      }, skip: gap); // BLE-679

      testWidgets('an open bottom sheet', (tester) async {
        await tester.pumpWidget(app());
        showModalBottomSheet<void>(
          context: tester.element(find.byKey(const ValueKey('bgText'))),
          builder: (_) => const SizedBox(height: 100, child: Text('sheet')),
        );
        await tester.pumpAndSettle();
        await expectBackgroundMasked(tester);
      }, skip: gap); // BLE-679

      testWidgets('an open popup menu', (tester) async {
        await tester.pumpWidget(app());
        await tester.tap(find.byKey(const ValueKey('popup')));
        await tester.pumpAndSettle();
        await expectBackgroundMasked(tester);
      }, skip: gap); // BLE-679
    });
  });
}
