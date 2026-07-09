import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat/src/anchors.dart';

const _semanticMapConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
  viewportSemanticMode: TugboatViewportSemanticMode.full,
);

const _semanticMapConfigWithLogs = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
  viewportSemanticMode: TugboatViewportSemanticMode.fullWithDebugLogs,
);

const _scrollSemanticMapConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  enableGlobalPointerCapture: false,
  scrollCaptureInterval: Duration.zero,
  captureScrollSamples: true,
  capturePixelRatio: 1.0,
  viewportSemanticMode: TugboatViewportSemanticMode.fullWithDebugLogs,
);

Future<void> _waitForSemanticMap(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    final controller = TugboatReplay.controller;
    final mapEvents =
        controller?.session?.events
            .where((event) => event.type == 'viewport_semantic_map')
            .toList() ??
        [];
    if (mapEvents.isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _waitForEvent(WidgetTester tester, String type) async {
  for (var attempt = 0; attempt < 60; attempt++) {
    final controller = TugboatReplay.controller;
    final events =
        controller?.session?.events.where((event) => event.type == type) ??
        const [];
    if (events.isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _waitForSceneInventory(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    final controller = TugboatReplay.controller;
    final inventoryEvents =
        controller?.session?.events
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
  testWidgets(
    'enabling viewport semantic map emits event after settled screen',
    (tester) async {
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
      expect(
        (payload['summary'] as Map<Object?, Object?>)['filteredCount'],
        isA<int>(),
      );
      expect(payload['nodes'], isA<List<dynamic>>());
      expect((payload['nodes'] as List).isNotEmpty, isTrue);
    },
  );

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
    final resolution =
        tapEvent.data['viewportSemanticResolution'] as Map<Object?, Object?>?;
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
            Semantics(
              label: 'Background copy',
              child: const Text('Background copy'),
            ),
          ],
        ),
      ),
      config: _semanticMapConfigWithLogs,
    );

    final controller = TugboatReplay.controller!;
    final mapEvent = controller.session!.events
        .where((event) => event.type == 'viewport_semantic_map')
        .single;
    final summary = mapEvent.data['summary'] as Map<Object?, Object?>;
    expect(summary['inventoryCount'], 0);
    final nodes = (mapEvent.data['nodes'] as List)
        .cast<Map<Object?, Object?>>();
    final textNode = nodes.singleWhere((node) => node['role'] == 'text');
    final bounds = textNode['boundsNorm'] as Map<Object?, Object?>;
    final scaffoldSize = tester.getSize(find.byType(Scaffold));
    controller.recordPointerDown(
      Offset(
        ((bounds['left'] as num).toDouble() +
                (bounds['width'] as num).toDouble() / 2) *
            scaffoldSize.width,
        ((bounds['top'] as num).toDouble() +
                (bounds['height'] as num).toDouble() / 2) *
            scaffoldSize.height,
      ),
    );
    await tester.pump();

    final tapEvent = controller.session!.events
        .where((event) => event.type == 'tap')
        .single;
    final resolution =
        tapEvent.data['viewportSemanticResolution'] as Map<Object?, Object?>?;
    expect(resolution, isNotNull);
    expect(resolution!['status'], 'matched_non_actionable');
    expect(
      controller.session!.events
          .where((event) => event.type == 'viewport_semantic_map')
          .length,
      1,
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
    final resolution =
        tapEvent.data['viewportSemanticResolution'] as Map<Object?, Object?>?;
    expect(resolution, isNotNull);
    expect(resolution!['status'], 'outside_known_ui');
  });

  testWidgets('inventory fallback covers gesture controls missing semantics', (
    tester,
  ) async {
    await _pumpSettledScreen(
      tester,
      Scaffold(
        body: Column(
          children: [
            FilledButton(onPressed: () {}, child: const Text('Plan')),
            const Spacer(),
            GestureDetector(
              excludeFromSemantics: true,
              onTap: () {},
              child: Container(
                key: const ValueKey('custom-cta'),
                height: 64,
                margin: const EdgeInsets.all(16),
                alignment: Alignment.center,
                color: Colors.blue,
                child: const Text('Unlock all AI tools'),
              ),
            ),
          ],
        ),
      ),
      config: _semanticMapConfigWithLogs,
    );

    final controller = TugboatReplay.controller!;
    final mapEvent = controller.session!.events
        .where((event) => event.type == 'viewport_semantic_map')
        .single;
    final payload = mapEvent.data;
    final summary = payload['summary'] as Map<Object?, Object?>;
    expect(summary['inventoryCount'], greaterThan(0));

    final nodes = (payload['nodes'] as List).cast<Map<Object?, Object?>>();
    final fallbackNodes = nodes
        .where(
          (node) =>
              node['source'] == 'inventory' &&
              node['role'] == 'button' &&
              (node['actions'] as List).contains('tap'),
        )
        .toList();
    expect(fallbackNodes, isNotEmpty);

    final ctaCenter = tester.getCenter(
      find.byKey(const ValueKey('custom-cta')),
    );
    controller.recordPointerDown(ctaCenter);
    await tester.pump();

    final tapEvent = controller.session!.events
        .where((event) => event.type == 'tap')
        .last;
    final resolution =
        tapEvent.data['viewportSemanticResolution'] as Map<Object?, Object?>?;
    expect(resolution, isNotNull);
    expect(resolution!['status'], 'matched_actionable');
    expect(resolution['linkedFingerprint'], isNotEmpty);
  });

  testWidgets('dormant profile stays off with default semantic mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.dormant,
            settleDelay: Duration.zero,
            enableGlobalPointerCapture: false,
            capturePixelRatio: 1.0,
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
      return;
    }

    final mapEvents =
        controller.session?.events
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
  });

  testWidgets('production default resolves taps without emitting maps', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.productionLean,
            settleDelay: Duration.zero,
            enableGlobalPointerCapture: false,
            capturePixelRatio: 1.0,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Go')),
        ),
      ),
    );
    await tester.pump();
    await _waitForCaptures(tester);

    final controller = TugboatReplay.controller!;

    final tapCenter = tester.getCenter(find.text('Go'));
    controller.recordPointerDown(tapCenter);
    await tester.pump();

    final mapEvents = controller.session!.events
        .where(
          (event) =>
              event.type == 'viewport_semantic_map' ||
              event.type == 'scroll_semantic_snapshot',
        )
        .toList();
    expect(mapEvents, isEmpty);

    final tapEvent = controller.session!.events
        .where((event) => event.type == 'tap')
        .last;
    final resolution =
        tapEvent.data['viewportSemanticResolution'] as Map<Object?, Object?>?;
    expect(resolution, isNotNull);
    expect(resolution!['status'], 'matched_actionable');
    // Verdict payload must remain text-free.
    expect(resolution.keys, isNot(contains('label')));
    expect(resolution.keys, isNot(contains('text')));
  });

  testWidgets('production semantic map requires explicit test opt-in', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.productionLean,
            settleDelay: Duration.zero,
            enableGlobalPointerCapture: false,
            capturePixelRatio: 1.0,
            viewportSemanticMode: TugboatViewportSemanticMode.full,
            viewportSemanticMapMaxNodes: 1,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Go')),
              FilledButton(onPressed: () {}, child: const Text('Next')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await _waitForCaptures(tester);

    final controller = TugboatReplay.controller!;
    controller.recordPointerDown(tester.getCenter(find.text('Go')));
    await tester.pump();

    final mapEvent = controller.session!.events
        .where((event) => event.type == 'viewport_semantic_map')
        .single;
    final nodes = mapEvent.data['nodes'] as List;
    final summary = mapEvent.data['summary'] as Map<Object?, Object?>;
    expect(nodes.length, lessThanOrEqualTo(1));
    expect(summary['truncatedCount'], isA<int>());
    expect(summary['totalNodes'], nodes.length);
  });

  testWidgets('production semantic map stays off with default mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.productionLean,
            settleDelay: Duration.zero,
            enableGlobalPointerCapture: false,
            capturePixelRatio: 1.0,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Go')),
              FilledButton(onPressed: () {}, child: const Text('Next')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await _waitForCaptures(tester);

    final controller = TugboatReplay.controller!;
    controller.recordPointerDown(tester.getCenter(find.text('Go')));
    await tester.pump();

    final mapEvents = controller.session!.events
        .where((event) => event.type == 'viewport_semantic_map')
        .toList();
    expect(mapEvents, isEmpty);
  });

  testWidgets(
    'scrolling emits semantic maps with scroll context and snapshot',
    (tester) async {
      await _pumpSettledScreen(
        tester,
        Scaffold(
          body: ListView.builder(
            itemCount: 40,
            itemBuilder: (context, index) =>
                ListTile(title: Text('Scroll item $index')),
          ),
        ),
        config: _scrollSemanticMapConfig,
      );

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await _waitForCaptures(tester);
      await _waitForEvent(tester, 'scroll_semantic_snapshot');

      final controller = TugboatReplay.controller!;
      final mapEvents = controller.session!.events
          .where((event) => event.type == 'viewport_semantic_map')
          .toList();
      final scrollMaps = mapEvents
          .where((event) => event.data.containsKey('scrollContext'))
          .toList();
      expect(scrollMaps, isNotEmpty);
      final scrollContext =
          scrollMaps.last.data['scrollContext'] as Map<Object?, Object?>;
      expect(scrollContext['trigger'], isNotEmpty);
      expect(scrollContext['axis'], 'vertical');

      final snapshotEvent = controller.session!.events
          .where((event) => event.type == 'scroll_semantic_snapshot')
          .last;
      expect(snapshotEvent.data['observedSliceCount'], greaterThanOrEqualTo(2));
      expect(snapshotEvent.data['observedNodeCount'], greaterThan(0));
      expect(snapshotEvent.data['snapshotHash'], isNotEmpty);
    },
  );

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
