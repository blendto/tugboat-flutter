import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tugboat/tugboat.dart';

/// Real-pixel characterization for modal/sheet capture (U8).
///
/// Uses encoded frame bytes from the live capture pipeline — never
/// [TugboatReplayController.debugSeedFrame] for modal assertions. Cases that
/// document a known production gap are marked `// GAP(U9):` and assert current
/// behavior so the suite stays green until U9 flips those expectations.
void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  testWidgets(
    'anonymous modal bottom sheet pixels differ from the base frame',
    (tester) async {
      final fixture = await _ModalVisualFixture.mount(tester);
      final baseFrame = await fixture.waitForLatestRealFrame(tester);
      final baseBottom = fixture.colorDominanceInBottom(baseFrame.id);

      final start = fixture.session.events.length;
      await tester.tap(find.byKey(_openAnonymousSheet));
      await tester.pumpAndSettle();
      final push = await fixture.waitForRoutePush(tester, after: start);
      await fixture.waitForCaptures(tester);

      final sheetFrameId = push.afterFrame;
      expect(
        sheetFrameId,
        isNotNull,
        reason: 'sheet route must attach a real after-frame',
      );
      final sheetBottom = fixture.colorDominanceInBottom(sheetFrameId!);

      expect(
        sheetBottom.greenDominant,
        greaterThan(20),
        reason: 'bottom region of the sheet frame must show green sheet pixels',
      );
      expect(
        baseBottom.redDominant,
        greaterThan(baseBottom.greenDominant),
        reason: 'base frame bottom region remains the red scaffold',
      );
      expect(push.data['route'], contains('ModalBottomSheetRoute'));
    },
  );

  testWidgets('draggable sheet terminal extent owns the accepted frame', (
    tester,
  ) async {
    final fixture = await _ModalVisualFixture.mount(tester);
    final start = fixture.session.events.length;
    await tester.tap(find.byKey(_openDraggableSheet));
    await tester.pumpAndSettle();
    final push = await fixture.waitForRoutePush(tester, after: start);
    await fixture.waitForCaptures(tester);

    final frameId = push.afterFrame;
    expect(frameId, isNotNull);
    final bottom = fixture.colorDominanceInBottom(frameId!);
    expect(
      bottom.tealDominant,
      greaterThan(20),
      reason: 'accepted frame must represent the settled teal sheet extent',
    );
  });

  testWidgets(
    'stacked anonymous sheets share runtime-type route identity today',
    (tester) async {
      final fixture = await _ModalVisualFixture.mount(tester);

      final firstStart = fixture.session.events.length;
      await tester.tap(find.byKey(_openAnonymousSheet));
      await tester.pumpAndSettle();
      final first = await fixture.waitForRoutePush(tester, after: firstStart);
      await fixture.waitForCaptures(tester);

      final secondStart = fixture.session.events.length;
      await tester.tap(find.byKey(_stackAnonymousSheet));
      await tester.pumpAndSettle();
      final second = await fixture.waitForRoutePush(tester, after: secondStart);
      await fixture.waitForCaptures(tester);

      final firstRoute = first.data['route'] as String;
      final secondRoute = second.data['route'] as String;
      expect(firstRoute, contains('ModalBottomSheetRoute'));
      expect(secondRoute, contains('ModalBottomSheetRoute'));

      // Opaque route-instance IDs distinguish stacked anonymous sheets even
      // when the descriptive route string collapses to the same runtime type.
      expect(first.data['routeInstanceId'], isNotNull);
      expect(second.data['routeInstanceId'], isNotNull);
      expect(
        first.data['routeInstanceId'],
        isNot(second.data['routeInstanceId']),
      );
      expect(first.data['navigatorId'], isNotNull);
      expect(second.data['navigatorId'], first.data['navigatorId']);
    },
  );

  testWidgets(
    'dismiss restores base-route pixels for action, barrier, and back',
    (tester) async {
      final fixture = await _ModalVisualFixture.mount(tester);
      final baseFrame = await fixture.waitForLatestRealFrame(tester);
      final baseCenter = fixture.sampleCenter(baseFrame.id);

      Future<void> openAndAssertSheet() async {
        final start = fixture.session.events.length;
        await tester.tap(find.byKey(_openNamedSheet));
        await tester.pumpAndSettle();
        final push = await fixture.waitForRoute(
          tester,
          navigation: 'route_push',
          route: '/named-sheet',
          after: start,
        );
        await fixture.waitForCaptures(tester);
        expect(push.afterFrame, isNotNull);
        final sheetBottom = fixture.colorDominanceInBottom(push.afterFrame!);
        expect(sheetBottom.greenDominant, greaterThan(20));
      }

      Future<void> assertRestoredBase({required int after}) async {
        final pop = await fixture.waitForRoute(
          tester,
          navigation: 'route_pop',
          route: '/root',
          after: after,
        );
        await fixture.waitForCaptures(tester);
        expect(pop.afterFrame, isNotNull);
        final restored = fixture.sampleCenter(pop.afterFrame!);
        expect(
          restored.r,
          greaterThan(restored.g),
          reason: 'restored base frame must show red scaffold pixels',
        );
        expect((restored.r - baseCenter.r).abs(), lessThan(40));
      }

      await openAndAssertSheet();
      var popStart = fixture.session.events.length;
      await tester.tap(find.byKey(_closeSheet));
      await tester.pumpAndSettle();
      await assertRestoredBase(after: popStart);

      await openAndAssertSheet();
      popStart = fixture.session.events.length;
      await tester.tapAt(const Offset(200, 80));
      await tester.pumpAndSettle();
      await assertRestoredBase(after: popStart);

      await openAndAssertSheet();
      popStart = fixture.session.events.length;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await assertRestoredBase(after: popStart);
    },
  );

  testWidgets(
    'named dialog and named sheet each attach distinct route evidence',
    (tester) async {
      final fixture = await _ModalVisualFixture.mount(tester);

      final dialogStart = fixture.session.events.length;
      await tester.tap(find.byKey(_openNamedDialog));
      await tester.pumpAndSettle();
      final dialog = await fixture.waitForRoute(
        tester,
        navigation: 'route_push',
        route: '/named-dialog',
        after: dialogStart,
      );
      await fixture.waitForCaptures(tester);
      expect(dialog.afterFrame, isNotNull);
      final dialogChannels = fixture.colorDominanceInCenter(dialog.afterFrame!);
      expect(
        dialogChannels.blueDominant,
        greaterThan(20),
        reason: 'dialog frame must show blue dialog surface',
      );

      await tester.tap(find.byKey(_closeDialog));
      await tester.pumpAndSettle();
      await fixture.waitForCaptures(tester);

      final sheetStart = fixture.session.events.length;
      await tester.tap(find.byKey(_openNamedSheet));
      await tester.pumpAndSettle();
      final sheet = await fixture.waitForRoute(
        tester,
        navigation: 'route_push',
        route: '/named-sheet',
        after: sheetStart,
      );
      await fixture.waitForCaptures(tester);
      expect(sheet.afterFrame, isNotNull);
      final sheetBottom = fixture.colorDominanceInBottom(sheet.afterFrame!);
      expect(sheetBottom.greenDominant, greaterThan(20));
    },
  );

  testWidgets('nested Navigator with observer records nested transition', (
    tester,
  ) async {
    final fixture = await _ModalVisualFixture.mount(tester);
    final hostStart = fixture.session.events.length;
    await tester.tap(find.byKey(_openNestedHost));
    await tester.pumpAndSettle();
    await fixture.waitForCaptures(tester);
    // Opening the nested host also bootstraps the nested Navigator's initial
    // route; pick the root host push by name.
    final hostPush = await fixture.waitForRoute(
      tester,
      navigation: 'route_push',
      route: '/nested-host',
      after: hostStart,
    );

    final start = fixture.session.events.length;
    await tester.tap(find.byKey(_openNestedSheet));
    await tester.pumpAndSettle();
    final push = await fixture.waitForRoutePush(tester, after: start);
    await fixture.waitForCaptures(tester);

    expect(push.afterFrame, isNotNull);
    expect(push.data['navigatorId'], isNotNull);
    expect(hostPush.data['navigatorId'], isNotNull);
    expect(
      push.data['navigatorId'],
      isNot(hostPush.data['navigatorId']),
      reason: 'nested Navigator must own a distinct navigatorId',
    );
  });

  testWidgets(
    'unobserved nested Navigator does not fabricate a root transition',
    (tester) async {
      final fixture = await _ModalVisualFixture.mount(
        tester,
        installNestedObserver: false,
      );
      await tester.tap(find.byKey(_openNestedHost));
      await tester.pumpAndSettle();
      await fixture.waitForCaptures(tester);

      final before = fixture.session.events
          .where((e) => e.type == 'route_change')
          .length;
      await tester.tap(find.byKey(_openNestedSheet));
      await tester.pumpAndSettle();
      await fixture.waitForCaptures(tester);

      final after = fixture.session.events
          .where((e) => e.type == 'route_change')
          .length;
      expect(
        after,
        before,
        reason:
            'unobserved nested navigation must not fabricate a root transition',
      );
    },
  );

  testWidgets('out-of-boundary surface must not borrow a prior Flutter frame', (
    tester,
  ) async {
    final fixture = await _ModalVisualFixture.mount(tester);
    final realFrames = fixture.session.frames
        .where((f) {
          final bytes = fixture.session.frameBytes[f.id];
          return bytes != null && bytes.isNotEmpty;
        })
        .map((f) => f.id)
        .toSet();
    expect(realFrames, isNotEmpty);

    // Unsupported / out-of-boundary surfaces must never re-label a prior
    // Flutter raster as proof. Real frames keep their own JPG identity.
    for (final frameId in realFrames) {
      final bytes = fixture.session.frameBytes[frameId]!;
      expect(img.decodeJpg(Uint8List.fromList(bytes)), isNotNull);
      expect(
        fixture.session.frameById(frameId)?.contentHash,
        isNot(equals('out_of_capture_boundary')),
      );
    }
  });

  testWidgets(
    'repeated named modal does not collapse ownership by name alone',
    (tester) async {
      final fixture = await _ModalVisualFixture.mount(tester);

      Future<TugboatEvent> openNamed() async {
        final start = fixture.session.events.length;
        await tester.tap(find.byKey(_openNamedSheet));
        await tester.pumpAndSettle();
        final push = await fixture.waitForRoute(
          tester,
          navigation: 'route_push',
          route: '/named-sheet',
          after: start,
        );
        await fixture.waitForCaptures(tester);
        return push;
      }

      final first = await openNamed();
      await tester.tap(find.byKey(_closeSheet));
      await tester.pumpAndSettle();
      await fixture.waitForCaptures(tester);
      final second = await openNamed();

      expect(first.data['route'], '/named-sheet');
      expect(second.data['route'], '/named-sheet');
      expect(first.data['routeInstanceId'], isNotNull);
      expect(second.data['routeInstanceId'], isNotNull);
      expect(
        first.data['routeInstanceId'],
        isNot(second.data['routeInstanceId']),
        reason: 'repeated named modals keep distinct routeInstanceId values',
      );
      expect(first.afterFrame, isNot(second.afterFrame));
      expect(
        fixture.colorDominanceInBottom(first.afterFrame!).greenDominant,
        greaterThan(20),
      );
      expect(
        fixture.colorDominanceInBottom(second.afterFrame!).greenDominant,
        greaterThan(20),
      );
    },
  );
}

const _openAnonymousSheet = Key('modal-open-anonymous-sheet');
const _stackAnonymousSheet = Key('modal-stack-anonymous-sheet');
const _openNamedSheet = Key('modal-open-named-sheet');
const _openNamedDialog = Key('modal-open-named-dialog');
const _openDraggableSheet = Key('modal-open-draggable-sheet');
const _closeSheet = Key('modal-close-sheet');
const _closeDialog = Key('modal-close-dialog');
const _openNestedHost = Key('modal-open-nested-host');
const _openNestedSheet = Key('modal-open-nested-sheet');

const _config = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: true,
  capturePixelRatio: 1,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
);

class _ColorDominance {
  const _ColorDominance({
    required this.redDominant,
    required this.greenDominant,
    required this.blueDominant,
    required this.tealDominant,
  });

  final int redDominant;
  final int greenDominant;
  final int blueDominant;
  final int tealDominant;
}

class _ModalVisualFixture {
  _ModalVisualFixture(this.controller);

  final TugboatReplayController controller;

  TugboatSession get session => controller.session!;

  static Future<_ModalVisualFixture> mount(
    WidgetTester tester, {
    bool installNestedObserver = true,
  }) async {
    final nestedObserver = TugboatReplay.createNavigatorObserver();
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/root',
        navigatorObservers: <NavigatorObserver>[
          TugboatReplay.navigatorObserver,
        ],
        routes: <String, WidgetBuilder>{
          '/root': (_) => _RootPage(
            nestedObserver: installNestedObserver ? nestedObserver : null,
          ),
        },
        // Mirror Blend: SDK boundary outside the Navigator child via builder.
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _config, child: child!),
      ),
    );
    final controller = await _pumpUntil(
      tester,
      () => TugboatReplay.controller,
      description: 'mounted replay controller',
    );
    await _pumpUntil(
      tester,
      () => controller.session,
      description: 'active replay session',
    );
    final fixture = _ModalVisualFixture(controller);
    await fixture.waitForCaptures(tester);
    return fixture;
  }

  Future<void> waitForCaptures(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 350));
    });
    await tester.pump();
    for (var i = 0; i < 16; i++) {
      if (!controller.debugRouteCapturePending &&
          !controller.debugCaptureInFlight) {
        break;
      }
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
  }

  Future<TugboatFrame> waitForLatestRealFrame(WidgetTester tester) async {
    return _pumpUntil(tester, () {
      for (final frame in session.frames.reversed) {
        final bytes = session.frameBytes[frame.id];
        if (bytes != null && bytes.isNotEmpty) return frame;
      }
      return null;
    }, description: 'real encoded frame');
  }

  Future<TugboatEvent> waitForRoute(
    WidgetTester tester, {
    required String navigation,
    required String route,
    required int after,
  }) => _pumpUntil(tester, () {
    for (final event in session.events.skip(after)) {
      if (event.type == 'route_change' &&
          event.data['navigation'] == navigation &&
          event.data['route'] == route) {
        return event;
      }
    }
    return null;
  }, description: '$navigation $route');

  Future<TugboatEvent> waitForRoutePush(
    WidgetTester tester, {
    required int after,
  }) => _pumpUntil(tester, () {
    for (final event in session.events.skip(after)) {
      if (event.type == 'route_change' &&
          event.data['navigation'] == 'route_push') {
        return event;
      }
    }
    return null;
  }, description: 'route_push');

  img.Pixel sampleCenter(String frameId) {
    final image = _decode(frameId);
    return image.getPixel(image.width ~/ 2, image.height ~/ 2);
  }

  _ColorDominance colorDominanceInBottom(String frameId) {
    final image = _decode(frameId);
    return _scan(image, startY: image.height ~/ 2, endY: image.height);
  }

  _ColorDominance colorDominanceInCenter(String frameId) {
    final image = _decode(frameId);
    final top = (image.height * 0.25).floor();
    final bottom = (image.height * 0.75).floor();
    return _scan(image, startY: top, endY: bottom);
  }

  _ColorDominance _scan(
    img.Image image, {
    required int startY,
    required int endY,
  }) {
    var red = 0;
    var green = 0;
    var blue = 0;
    var teal = 0;
    final x0 = image.width ~/ 4;
    final x1 = (image.width * 3) ~/ 4;
    for (var y = startY; y < endY; y += 2) {
      for (var x = x0; x < x1; x += 4) {
        final p = image.getPixel(x, y);
        final r = p.r.toInt();
        final g = p.g.toInt();
        final b = p.b.toInt();
        if (r > g + 40 && r > b + 40) red++;
        if (g > r + 40 && g > b + 40) green++;
        if (b > r + 40 && b > g + 40) blue++;
        if (g > r + 40 && b > r + 40) teal++;
      }
    }
    return _ColorDominance(
      redDominant: red,
      greenDominant: green,
      blueDominant: blue,
      tealDominant: teal,
    );
  }

  img.Image _decode(String frameId) {
    final bytes = session.frameBytes[frameId];
    expect(bytes, isNotNull, reason: 'frame $frameId must have bytes');
    expect(bytes!, isNotEmpty, reason: 'frame $frameId must be a real raster');
    final decoded = img.decodeJpg(Uint8List.fromList(bytes));
    expect(decoded, isNotNull, reason: 'frame $frameId must decode as JPEG');
    return decoded!;
  }
}

class _RootPage extends StatelessWidget {
  const _RootPage({this.nestedObserver});

  final NavigatorObserver? nestedObserver;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFCC0000),
    body: ListView(
      children: <Widget>[
        FilledButton(
          key: _openAnonymousSheet,
          onPressed: () => _openSheet(context, named: false, stackable: true),
          child: const Text('anonymous sheet'),
        ),
        FilledButton(
          key: _openNamedSheet,
          onPressed: () => _openSheet(context, named: true),
          child: const Text('named sheet'),
        ),
        FilledButton(
          key: _openNamedDialog,
          onPressed: () => showGeneralDialog<void>(
            context: context,
            barrierDismissible: true,
            barrierLabel: 'dismiss',
            routeSettings: const RouteSettings(name: '/named-dialog'),
            pageBuilder: (context, _, _) => Center(
              child: Material(
                color: const Color(0xFF0033CC),
                child: SizedBox(
                  width: 220,
                  height: 160,
                  child: Center(
                    child: FilledButton(
                      key: _closeDialog,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('close dialog'),
                    ),
                  ),
                ),
              ),
            ),
          ),
          child: const Text('named dialog'),
        ),
        FilledButton(
          key: _openDraggableSheet,
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (context) => DraggableScrollableSheet(
              initialChildSize: 0.55,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              builder: (context, controller) => ColoredBox(
                color: const Color(0xFF008888),
                child: ListView(
                  controller: controller,
                  children: const <Widget>[
                    SizedBox(height: 24),
                    Center(child: Text('draggable')),
                    SizedBox(height: 400),
                  ],
                ),
              ),
            ),
          ),
          child: const Text('draggable sheet'),
        ),
        FilledButton(
          key: _openNestedHost,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/nested-host'),
              builder: (_) => _NestedHost(observer: nestedObserver),
            ),
          ),
          child: const Text('nested host'),
        ),
      ],
    ),
  );

  void _openSheet(
    BuildContext context, {
    required bool named,
    bool stackable = false,
  }) {
    showModalBottomSheet<void>(
      context: context,
      routeSettings: named ? const RouteSettings(name: '/named-sheet') : null,
      backgroundColor: const Color(0xFF00AA00),
      builder: (context) => ColoredBox(
        color: const Color(0xFF00AA00),
        child: SizedBox(
          height: 180,
          child: Column(
            children: <Widget>[
              FilledButton(
                key: _closeSheet,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('close sheet'),
              ),
              if (stackable)
                FilledButton(
                  key: _stackAnonymousSheet,
                  onPressed: () =>
                      _openSheet(context, named: false, stackable: false),
                  child: const Text('stack sheet'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NestedHost extends StatelessWidget {
  const _NestedHost({this.observer});

  final NavigatorObserver? observer;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF884400),
    body: Navigator(
      observers: <NavigatorObserver>[if (observer != null) observer!],
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (context) => Center(
          child: FilledButton(
            key: _openNestedSheet,
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: const Color(0xFF00AA00),
              builder: (context) => const ColoredBox(
                color: Color(0xFF00AA00),
                child: SizedBox(
                  height: 120,
                  child: Center(child: Text('nested sheet')),
                ),
              ),
            ),
            child: const Text('nested sheet'),
          ),
        ),
      ),
    ),
  );
}

Future<T> _pumpUntil<T>(
  WidgetTester tester,
  T? Function() read, {
  required String description,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final value = read();
    if (value != null) return value;
    await tester.pump();
    if (attempt > 0 && attempt % 10 == 0) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
  }
  fail('Timed out waiting for $description');
}
