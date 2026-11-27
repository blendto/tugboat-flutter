// BLE-679: the screenshot mask walk is pixels-only and fails closed.
//
// It must not reuse the identity walk's pruning (excluding semantics, modal
// shadowing, TugboatInternal), and a mask that cannot be computed must fail
// the capture instead of sending an unmasked frame. Every assertion reads the
// rects handed to the pixel source by the real ScreenshotCapturer.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

const _all = TugboatScreenshotMaskLevel.allTextAndMedia;
const _explicit = TugboatScreenshotMaskLevel.explicitOnly;
const _inputs = TugboatScreenshotMaskLevel.sensitiveInputsOnly;

/// What one capture handed to the pixel source, or why it failed.
class _Capture {
  _Capture(this.masks, this.failure);

  final List<Rect> masks;
  final ScreenshotCaptureFailure? failure;
}

Future<_Capture> _capture(
  GlobalKey boundaryKey,
  TugboatScreenshotMaskLevel level,
) async {
  final source = _RecordingPixelSource();
  final capturer = ScreenshotCapturer(
    boundaryKey: boundaryKey,
    maskLevel: level,
    anchorResolver: AnchorResolver(rootKey: boundaryKey),
    pixelRatio: 1,
    pixelSource: source,
  );
  addTearDown(capturer.dispose);
  final attempt = await capturer.captureAttempt(waitForFrame: false);
  return _Capture(
    source.requests.isEmpty ? const [] : source.requests.single.maskRects,
    attempt.failure,
  );
}

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

bool _contains(Rect outer, Rect inner) =>
    outer.left <= inner.left + 0.5 &&
    outer.top <= inner.top + 0.5 &&
    outer.right >= inner.right - 0.5 &&
    outer.bottom >= inner.bottom - 0.5;

bool _covers(List<Rect> masks, Rect target) =>
    masks.any((mask) => _contains(mask, target));

bool _touches(List<Rect> masks, Rect target) =>
    masks.any((mask) => mask.overlaps(target));

Future<GlobalKey> _pumpBody(WidgetTester tester, Widget body) async {
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
  return boundaryKey;
}

const _k = ValueKey('target');
const _panelKey = ValueKey('panel');
const _panel = SizedBox(
  key: _panelKey,
  width: 80,
  height: 40,
  child: ColoredBox(color: Colors.black),
);

Finder _inner(Finder finder, Type type) =>
    find.descendant(of: finder, matching: find.byType(type));

void main() {
  /// Mounts [body], captures at [level] and expects [target] masked.
  Future<void> expectMasked(
    WidgetTester tester,
    TugboatScreenshotMaskLevel level,
    Widget body,
    Finder target,
  ) async {
    final key = await _pumpBody(tester, body);
    final result = await _capture(key, level);
    expect(result.failure, isNot(ScreenshotCaptureFailure.maskFailed));
    final bounds = _boundsOf(tester, target);
    expect(
      _covers(result.masks, bounds),
      isTrue,
      reason: 'expected a mask over $bounds, got ${result.masks}',
    );
  }

  group('painted content that looks hidden or excluded is masked', () {
    testWidgets('Text(semanticsLabel:)', (tester) async {
      await expectMasked(
        tester,
        _all,
        const Text('Balance 4242.00', semanticsLabel: 'balance', key: _k),
        _inner(find.byKey(_k), RichText),
      );
    });

    testWidgets('Icon(semanticLabel:)', (tester) async {
      await expectMasked(
        tester,
        _all,
        const Icon(Icons.add, semanticLabel: 'add', key: _k),
        _inner(find.byKey(_k), RichText),
      );
    });

    testWidgets('ExcludeSemantics > Text', (tester) async {
      await expectMasked(
        tester,
        _all,
        const ExcludeSemantics(child: Text('Card 4242', key: _k)),
        find.byKey(_k),
      );
    });

    testWidgets('ExcludeSemantics > TextField', (tester) async {
      await expectMasked(
        tester,
        _all,
        ExcludeSemantics(
          child: SizedBox(
            width: 200,
            child: TextField(
              controller: TextEditingController(text: '4242 4242'),
            ),
          ),
        ),
        find.byType(EditableText),
      );
    });

    testWidgets('ExcludeSemantics > obscured TextField (sensitiveInputsOnly)', (
      tester,
    ) async {
      await expectMasked(
        tester,
        _inputs,
        ExcludeSemantics(
          child: SizedBox(
            width: 200,
            child: TextField(
              controller: TextEditingController(text: 'pw'),
              obscureText: true,
            ),
          ),
        ),
        find.byType(EditableText),
      );
    });

    testWidgets('ExcludeSemantics > RawImage', (tester) async {
      await expectMasked(
        tester,
        _all,
        const ExcludeSemantics(
          child: SizedBox(width: 40, height: 40, child: RawImage(key: _k)),
        ),
        find.byKey(_k),
      );
    });

    testWidgets('ExcludeSemantics > TugboatSensitive (explicitOnly)', (
      tester,
    ) async {
      await expectMasked(
        tester,
        _explicit,
        const ExcludeSemantics(child: TugboatSensitive(child: _panel)),
        find.byKey(_panelKey),
      );
    });

    testWidgets('ExcludeSemantics > TugboatSensitive (allTextAndMedia)', (
      tester,
    ) async {
      await expectMasked(
        tester,
        _all,
        const ExcludeSemantics(child: TugboatSensitive(child: _panel)),
        find.byKey(_panelKey),
      );
    });

    testWidgets('TugboatSensitive > ExcludeSemantics > panel', (tester) async {
      await expectMasked(
        tester,
        _explicit,
        const TugboatSensitive(child: ExcludeSemantics(child: _panel)),
        find.byKey(_panelKey),
      );
    });

    testWidgets('AnimatedCrossFade outgoing child', (tester) async {
      final key = GlobalKey();
      Widget app(CrossFadeState state) => MaterialApp(
        home: Scaffold(
          body: TugboatCaptureBoundary(
            key: key,
            child: Align(
              alignment: Alignment.topLeft,
              child: AnimatedCrossFade(
                firstChild: const Text(
                  'outgoing outgoing outgoing',
                  key: ValueKey('out'),
                ),
                secondChild: const Text('in', key: ValueKey('in')),
                crossFadeState: state,
                duration: const Duration(seconds: 1),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(CrossFadeState.showFirst));
      await tester.pumpWidget(app(CrossFadeState.showSecond));
      await tester.pump(const Duration(milliseconds: 300));
      final result = await _capture(key, _all);
      expect(result.failure, isNot(ScreenshotCaptureFailure.maskFailed));
      expect(
        _covers(
          result.masks,
          _boundsOf(tester, find.byKey(const ValueKey('out'))),
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
    });

    testWidgets(
      'Visibility(visible: false, replacement:) paints the replacement',
      (tester) async {
        await expectMasked(
          tester,
          _all,
          const Visibility(
            visible: false,
            replacement: Text('Card 4242 4242', key: _k),
            child: SizedBox(),
          ),
          find.byKey(_k),
        );
      },
    );

    testWidgets('TugboatSensitive in a Visibility replacement is masked', (
      tester,
    ) async {
      await expectMasked(
        tester,
        _explicit,
        const Visibility(
          visible: false,
          replacement: TugboatSensitive(child: _panel),
          child: SizedBox(),
        ),
        find.byKey(_panelKey),
      );
    });
  });

  group('controls that already mask', () {
    testWidgets('plain Text', (tester) async {
      await expectMasked(
        tester,
        _all,
        const Text('Card 4242', key: _k),
        find.byKey(_k),
      );
    });

    testWidgets('ExcludeSemantics(excluding: false) > Text', (tester) async {
      await expectMasked(
        tester,
        _all,
        const ExcludeSemantics(
          excluding: false,
          child: Text('Card 4242', key: _k),
        ),
        find.byKey(_k),
      );
    });

    testWidgets('Semantics(excludeSemantics: true) > Text', (tester) async {
      await expectMasked(
        tester,
        _all,
        Semantics(
          label: 'x',
          excludeSemantics: true,
          child: const Text('Card 4242', key: _k),
        ),
        find.byKey(_k),
      );
    });

    testWidgets('TugboatSensitive > Text(semanticsLabel:) at explicitOnly', (
      tester,
    ) async {
      await expectMasked(
        tester,
        _explicit,
        const TugboatSensitive(
          child: Text('Balance 4242.00', semanticsLabel: 'balance', key: _k),
        ),
        _inner(find.byKey(_k), RichText),
      );
    });

    testWidgets('unclipped zero-size parent still paints its Text children', (
      tester,
    ) async {
      await expectMasked(
        tester,
        _all,
        const SizedBox(
          width: 0,
          height: 0,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            minHeight: 0,
            maxWidth: 200,
            maxHeight: 40,
            child: Text('Card 4242', key: _k),
          ),
        ),
        find.byKey(_k),
      );
    });

    testWidgets('Visibility(maintainState) hidden child stays unmasked', (
      tester,
    ) async {
      final key = await _pumpBody(
        tester,
        const Column(
          children: [
            Text('visible'),
            Visibility(
              visible: false,
              maintainState: true,
              child: Text('gone', key: _k),
            ),
          ],
        ),
      );
      final result = await _capture(key, _all);
      expect(result.masks, hasLength(1));
    });

    testWidgets('Offstage Text is not painted, so not masked', (tester) async {
      final key = await _pumpBody(
        tester,
        const Column(
          children: [
            Text('visible'),
            Offstage(child: Text('hidden', key: _k)),
          ],
        ),
      );
      final result = await _capture(key, _all);
      expect(result.failure, isNot(ScreenshotCaptureFailure.maskFailed));
      expect(result.masks, hasLength(1), reason: 'only the visible Text');
    });

    testWidgets('opacity 0 Text is not painted, so not masked', (tester) async {
      final key = await _pumpBody(
        tester,
        const Column(
          children: [
            Text('visible'),
            Opacity(opacity: 0, child: Text('ghost', key: _k)),
          ],
        ),
      );
      final result = await _capture(key, _all);
      expect(result.failure, isNot(ScreenshotCaptureFailure.maskFailed));
      expect(result.masks, hasLength(1));
    });

    testWidgets('invisible Visibility Text is not masked', (tester) async {
      final key = await _pumpBody(
        tester,
        const Column(
          children: [
            Text('visible'),
            Visibility(visible: false, child: Text('gone', key: _k)),
          ],
        ),
      );
      final result = await _capture(key, _all);
      expect(result.failure, isNot(ScreenshotCaptureFailure.maskFailed));
      expect(result.masks, hasLength(1));
    });
  });

  group('content behind a modal route stays masked', () {
    final boundaryKey = GlobalKey();
    final scaffoldKey = GlobalKey<ScaffoldState>();

    Widget app() => TugboatCaptureBoundary(
      key: boundaryKey,
      child: MaterialApp(
        home: Scaffold(
          key: scaffoldKey,
          drawer: const Drawer(child: Text('drawer item')),
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
      final result = await _capture(boundaryKey, _all);
      expect(result.failure, isNot(ScreenshotCaptureFailure.maskFailed));
      for (final id in ['bgText', 'bgSensitive']) {
        final bounds = _boundsOf(tester, find.byKey(ValueKey(id)));
        expect(
          _covers(result.masks, bounds),
          isTrue,
          reason: '$id must be masked behind the modal; masks=${result.masks}',
        );
      }
    }

    testWidgets('showDialog', (tester) async {
      await tester.pumpWidget(app());
      final context = tester.element(find.byKey(const ValueKey('bgText')));
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(title: Text('Confirm')),
      );
      await tester.pumpAndSettle();
      await expectBackgroundMasked(tester);
      final result = await _capture(boundaryKey, _all);
      expect(
        _covers(result.masks, _boundsOf(tester, find.text('Confirm'))),
        isTrue,
      );
    });

    testWidgets('showModalBottomSheet', (tester) async {
      await tester.pumpWidget(app());
      final context = tester.element(find.byKey(const ValueKey('bgText')));
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 100, child: Text('sheet')),
      );
      await tester.pumpAndSettle();
      await expectBackgroundMasked(tester);
    });

    testWidgets('PopupMenuButton menu', (tester) async {
      await tester.pumpWidget(app());
      await tester.tap(find.byKey(const ValueKey('popup')));
      await tester.pumpAndSettle();
      await expectBackgroundMasked(tester);
    });

    testWidgets('Scaffold drawer (control)', (tester) async {
      await tester.pumpWidget(app());
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
      await expectBackgroundMasked(tester);
    });

    testWidgets('page below an opaque route is not painted, so not masked', (
      tester,
    ) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        TugboatCaptureBoundary(
          key: key,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Align(
                  alignment: Alignment.bottomLeft,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      PageRouteBuilder<void>(
                        transitionDuration: Duration.zero,
                        pageBuilder: (_, _, _) =>
                            const Scaffold(body: Text('second page')),
                      ),
                    ),
                    child: const Text('first page', key: _k),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(_k));
      await tester.pumpAndSettle();
      // The covered page is still mounted (maintainState) but not painted.
      final firstBounds = _boundsOf(
        tester,
        find.byKey(_k, skipOffstage: false),
      );
      final result = await _capture(key, _all);
      expect(result.failure, isNot(ScreenshotCaptureFailure.maskFailed));
      expect(_touches(result.masks, firstBounds), isFalse);
      expect(
        _covers(result.masks, _boundsOf(tester, find.text('second page'))),
        isTrue,
      );
    });
  });

  group('TugboatInternal suppresses identity, not pixels', () {
    testWidgets('TugboatInternal > Text', (tester) async {
      await expectMasked(
        tester,
        _all,
        const TugboatInternal(child: Text('Card 4242', key: _k)),
        find.byKey(_k),
      );
    });

    testWidgets('TugboatInternal > TugboatSensitive (explicitOnly)', (
      tester,
    ) async {
      await expectMasked(
        tester,
        _explicit,
        const TugboatInternal(child: TugboatSensitive(child: _panel)),
        find.byKey(_panelKey),
      );
    });
  });

  group('fails closed', () {
    testWidgets('a transform failure fails the capture with maskFailed', (
      tester,
    ) async {
      final key = await _pumpBody(
        tester,
        const _ThrowingImage(key: _k, width: 40, height: 40),
      );
      final result = await _capture(key, _all);
      expect(result.failure, ScreenshotCaptureFailure.maskFailed);
      expect(result.masks, isEmpty);
    });

    testWidgets('no mounted root throws instead of returning no masks', (
      tester,
    ) async {
      final resolver = AnchorResolver(rootKey: GlobalKey());
      await tester.pumpWidget(const SizedBox());
      expect(
        () => resolver.collectMaskRects(
          rootRender: tester.renderObject<RenderBox>(find.byType(SizedBox)),
          shouldMask: (_, _, _, _, _) => true,
        ),
        throwsStateError,
      );
    });

    testWidgets('a non-finite mask rect fails the capture', (tester) async {
      final key = await _pumpBody(
        tester,
        const _NanImage(key: _k, width: 40, height: 40),
      );
      final result = await _capture(key, _all);
      expect(result.failure, ScreenshotCaptureFailure.maskFailed);
    });

    testWidgets('an all-zero transform (not painted) is skipped', (
      tester,
    ) async {
      final key = await _pumpBody(
        tester,
        const _ZeroImage(key: _k, width: 40, height: 40),
      );
      final result = await _capture(key, _all);
      expect(result.failure, isNot(ScreenshotCaptureFailure.maskFailed));
      expect(result.masks, isEmpty);
    });
  });
}

/// A media box whose transform to the capture root cannot be computed.
class _ThrowingImage extends LeafRenderObjectWidget {
  const _ThrowingImage({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ThrowingRenderImage(width: width, height: height);
}

class _ThrowingRenderImage extends RenderImage {
  _ThrowingRenderImage({super.width, super.height});

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) {
    if (ancestor is RenderRepaintBoundary) {
      throw StateError('transform unavailable');
    }
    return super.getTransformTo(ancestor);
  }
}

class _NanImage extends LeafRenderObjectWidget {
  const _NanImage({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _NanRenderImage(width: width, height: height, zero: false);
}

class _ZeroImage extends LeafRenderObjectWidget {
  const _ZeroImage({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _NanRenderImage(width: width, height: height, zero: true);
}

class _NanRenderImage extends RenderImage {
  _NanRenderImage({super.width, super.height, required this.zero});

  final bool zero;

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) {
    if (ancestor is RenderRepaintBoundary) {
      return zero
          ? Matrix4.zero()
          : (Matrix4.identity()..setEntry(0, 3, double.nan));
    }
    return super.getTransformTo(ancestor);
  }
}
