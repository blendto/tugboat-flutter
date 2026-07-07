import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat/src/anchors.dart' show AnchorResolver;

const _semanticMapConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
  enableViewportSemanticMap: true,
);

const _semanticMapConfigWithLogs = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
  enableViewportSemanticMap: true,
  enableViewportSemanticMapDebugLogs: true,
);

Future<void> _waitForSemanticMap(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    final controller = TugboatReplay.controller;
    final mapEvents = controller?.session?.events
            .where((event) => event.type == 'viewport_semantic_map')
            .toList() ??
        [];
    if (mapEvents.isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _waitForSceneInventory(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    final controller = TugboatReplay.controller;
    final inventoryEvents = controller?.session?.events
            .where((event) => event.type == 'scene_inventory')
            .toList() ??
        [];
    if (inventoryEvents.isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _waitForCaptures(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
}

Future<void> _pumpSettledScreen(
  WidgetTester tester,
  Widget home, {
  TugboatReplayConfig config = _semanticMapConfig,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: config, child: child!),
      home: home,
    ),
  );
  await tester.pump();
  await _waitForCaptures(tester);
  await _waitForSceneInventory(tester);
  await _waitForSemanticMap(tester);
}

void main() {
  testWidgets('enabling viewport semantic map emits event after settled screen', (
    tester,
  ) async {
    await _pumpSettledScreen(
      tester,
      Scaffold(
        body: FilledButton(onPressed: () {}, child: const Text('Go')),
      ),
    );

    final controller = TugboatReplay.controller!;
    final mapEvents = controller.session!.events
        .where((event) => event.type == 'viewport_semantic_map')
        .toList();

    expect(mapEvents, isNotEmpty);
    final payload = mapEvents.single.data;
    expect(payload['stateSignature'], isNotEmpty);
    expect(payload['routeKey'], isNotEmpty);
    expect(payload['mapHash'], isNotEmpty);
    expect(payload['summary'], isA<Map<Object?, Object?>>());
    expect(payload['nodes'], isA<List<dynamic>>());
    expect((payload['nodes'] as List).isNotEmpty, isTrue);
  });

  testWidgets('tap on button resolves to matched_actionable with fingerprint', (
    tester,
  ) async {
    await _pumpSettledScreen(
      tester,
      Scaffold(
        body: FilledButton(onPressed: () {}, child: const Text('Go')),
      ),
    );

    final controller = TugboatReplay.controller!;
    final tapCenter = tester.getCenter(find.text('Go'));
    controller.recordPointerDown(tapCenter);
    await tester.pump();

    final tapEvent = controller.session!.events
        .where((event) => event.type == 'tap')
        .single;
    final resolution = tapEvent.data['viewportSemanticResolution']
        as Map<Object?, Object?>?;
    expect(resolution, isNotNull);
    expect(resolution!['status'], 'matched_actionable');
    expect(resolution['linkedFingerprint'], isNotEmpty);
    expect(resolution['role'], 'button');

    final tapFingerprint = tapEvent.targetAnchor?.fingerprint;
    expect(tapFingerprint, isNotEmpty);
    expect(resolution['linkedFingerprint'], tapFingerprint);
  });

  testWidgets('tap on non-actionable text resolves to matched_non_actionable', (
    tester,
  ) async {
    await _pumpSettledScreen(
      tester,
      Scaffold(
        body: Column(
          children: [
            FilledButton(onPressed: () {}, child: const Text('Go')),
            const SizedBox(height: 24),
            const Text('Background copy'),
          ],
        ),
      ),
    );

    final controller = TugboatReplay.controller!;
    final textCenter = tester.getCenter(find.text('Background copy'));
    controller.recordPointerDown(textCenter);
    await tester.pump();

    final tapEvent = controller.session!.events
        .where((event) => event.type == 'tap')
        .single;
    final resolution = tapEvent.data['viewportSemanticResolution']
        as Map<Object?, Object?>?;
    expect(resolution, isNotNull);
    expect(
      resolution!['status'],
      anyOf('matched_non_actionable', 'outside_known_ui'),
    );
  });

  testWidgets('tap outside known ui resolves to outside_known_ui', (
    tester,
  ) async {
    await _pumpSettledScreen(
      tester,
      Scaffold(
        body: FilledButton(onPressed: () {}, child: const Text('Go')),
      ),
    );

    final controller = TugboatReplay.controller!;
    final bottomRight = tester.getBottomRight(find.byType(Scaffold));
    controller.recordPointerDown(bottomRight - const Offset(2, 2));
    await tester.pump();

    final tapEvent = controller.session!.events
        .where((event) => event.type == 'tap')
        .single;
    final resolution = tapEvent.data['viewportSemanticResolution']
        as Map<Object?, Object?>?;
    expect(resolution, isNotNull);
    expect(resolution!['status'], 'outside_known_ui');
  });

  testWidgets('dormant and production profiles do not emit viewport maps', (
    tester,
  ) async {
    for (final profile in [
      TugboatCaptureProfile.dormant,
      TugboatCaptureProfile.productionLean,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => TugboatReplay.wrapApp(
            config: TugboatReplayConfig(
              profile: profile,
              settleDelay: Duration.zero,
              enableGlobalPointerCapture: false,
              capturePixelRatio: 1.0,
              enableViewportSemanticMap: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: FilledButton(onPressed: () {}, child: const Text('Go')),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final controller = TugboatReplay.controller;
      if (controller == null) {
        continue;
      }

      final mapEvents = controller.session?.events
              .where((event) => event.type == 'viewport_semantic_map')
              .toList() ??
          [];
      expect(mapEvents, isEmpty);

      final tapCenter = tester.getCenter(find.text('Go'));
      controller.recordPointerDown(tapCenter);
      await tester.pump();

      final tapEvent = controller.session!.events
          .where((event) => event.type == 'tap')
          .last;
      expect(tapEvent.data.containsKey('viewportSemanticResolution'), isFalse);
    }
  });

  testWidgets('scene inventory emission remains unchanged with semantic map', (
    tester,
  ) async {
    await _pumpSettledScreen(
      tester,
      Scaffold(
        body: FilledButton(onPressed: () {}, child: const Text('Go')),
      ),
    );

    final controller = TugboatReplay.controller!;
    final inventoryEvents = controller.session!.events
        .where((event) => event.type == 'scene_inventory')
        .toList();
    expect(inventoryEvents, isNotEmpty);

    final inventory = inventoryEvents.single.data;
    expect(inventory['elements'], isA<List<dynamic>>());
    expect((inventory['elements'] as List).isNotEmpty, isTrue);
  });

  testWidgets('debug log config does not change emitted payload shape', (
    tester,
  ) async {
    await _pumpSettledScreen(
      tester,
      Scaffold(
        body: FilledButton(onPressed: () {}, child: const Text('Go')),
      ),
      config: _semanticMapConfigWithLogs,
    );

    final controller = TugboatReplay.controller!;
    final mapEvent = controller.session!.events
        .where((event) => event.type == 'viewport_semantic_map')
        .single;
    expect(mapEvent.data['mapHash'], isNotEmpty);
    expect(mapEvent.data['summary'], isA<Map<Object?, Object?>>());
  });

  testWidgets('resolver links semantic nodes to inventory fingerprints', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: FilledButton(onPressed: () {}, child: const Text('Go')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    final resolver = AnchorResolver(rootKey: rootKey);
    final inventory = resolver.buildSceneInventory(
      route: '/home',
      keyboardOpen: false,
      modalOpen: false,
    );
    expect(inventory, isNotNull);

    final map = resolver.buildViewportSemanticMap(inventory: inventory!);
    expect(map, isNotNull);
    expect(
      map!.nodes.any((node) => node.linkedFingerprint?.isNotEmpty == true),
      isTrue,
    );

    final buttonCenter = tester.getCenter(find.text('Go'));
    final rootRender = rootKey.currentContext!.findRenderObject()! as RenderBox;
    final resolution = resolver.resolveTapOnViewportSemanticMap(
      tapPosition: buttonCenter,
      map: map,
      rootRender: rootRender,
    );
    expect(resolution.status, 'matched_actionable');
    expect(resolution.linkedFingerprint, isNotEmpty);
  });
}
