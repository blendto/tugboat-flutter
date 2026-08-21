import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/interaction_transaction.dart';
import 'package:tugboat/tugboat.dart';

const _explorationConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1,
);

class _DelayedCta extends StatefulWidget {
  const _DelayedCta();

  @override
  State<_DelayedCta> createState() => _DelayedCtaState();
}

class _DelayedCtaState extends State<_DelayedCta> {
  Timer? _timer;
  bool _showCta = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showCta = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: IgnorePointer(
          ignoring: !_showCta,
          child: AnimatedOpacity(
            opacity: _showCta ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: FilledButton(
              onPressed: () {},
              child: const Text('Continue'),
            ),
          ),
        ),
      ),
    );
  }
}

Future<TugboatReplayController> _mountController(
  WidgetTester tester,
  Widget child, {
  TugboatReplayConfig config = _explorationConfig,
}) async {
  TugboatReplay.debugConfigureControllerForTest = (controller) {
    controller.debugExecuteCapture =
        ({required trigger, required force}) async =>
            controller.debugSeedFrame(trigger: trigger);
  };
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, appChild) =>
          TugboatReplay.wrapApp(config: config, child: appChild!),
      home: child,
    ),
  );
  await tester.pump();
  await tester.pump();
  final controller = TugboatReplay.controller;
  expect(controller, isNotNull);
  expect(controller!.session, isNotNull);
  return controller;
}

Future<void> _finishInteraction(
  WidgetTester tester,
  TugboatReplayController controller,
) async {
  await tester.pump();
  await controller.drainPointerQueue();
  await tester.pump(const Duration(milliseconds: 350));
  await controller.drainPointerQueue();
}

TugboatEvent _lastInteraction(TugboatReplayController controller) => controller
    .session!
    .events
    .where((event) => event.type == 'interaction')
    .last;

void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  test(
    'fallback confidence and missing-target reasons use interaction fields',
    () {
      const origin = InteractionOrigin(
        interactionId: 'interaction-1',
        route: '/subscriptionPaywall',
        routeEpoch: 3,
        routeInstanceId: 'route-instance-1',
        navigatorId: 'navigator-1',
        targetAnchor: null,
        captureCoordinate: TugboatCaptureCoordinate.unavailable(
          unavailableReason: 'test',
        ),
        beforeFrame: null,
        atMs: 10,
        startPosition: Offset(44, 44),
        pointerGeneration: 2,
        captureSessionId: 'session-1',
      );
      const fallbackTarget = TugboatTargetAnchor(
        role: 'button',
        fingerprint: 'close-fingerprint',
        fingerprintConfidence: 'low',
        canonicalPath: 'Stack#0/IconButton#0',
        enabled: true,
        actions: ['tap'],
      );
      final fallback = InteractionTransaction(origin: origin, pointerId: 1)
        ..targetAnchor = fallbackTarget
        ..preTapEvidence = const TugboatPreTapEvidence(
          route: '/subscriptionPaywall',
          routeEpoch: 3,
          routeInstanceId: 'route-instance-1',
          pointerPosition: Offset(44, 44),
          targetAnchor: fallbackTarget,
          inventory: null,
          semanticMap: null,
          semanticResolution: TugboatViewportSemanticResolution(
            status: 'matched_inventory_fallback',
            linkedFingerprint: 'close-fingerprint',
            fingerprintConfidence: 'low',
          ),
          visualObservationGeneration: 4,
          frameCompletionSequence: 5,
          buildMicros: 1200,
          failureReason: null,
        );

      expect(
        buildInteractionV2Payload(fallback),
        containsPair('targetFingerprint', 'close-fingerprint'),
      );
      expect(
        buildInteractionV2Payload(fallback)['fingerprintConfidence'],
        'low',
      );

      final missing = InteractionTransaction(origin: origin, pointerId: 2)
        ..targetResolutionFailureReason =
            TugboatTargetResolutionFailureReason.noTargetAtPoint;
      expect(
        buildInteractionV2Payload(missing)['targetResolutionFailureReason'],
        'no_target_at_point',
      );
    },
  );

  testWidgets(
    'delayed AnimatedOpacity and IgnorePointer CTA uses pointer-down inventory',
    (tester) async {
      final controller = await _mountController(tester, const _DelayedCta());
      controller.debugSetCurrentRoute('/intro');

      final initialResolver = AnchorResolver(rootKey: controller.boundaryKey);
      final initialInventory = initialResolver.buildSceneInventory(
        route: '/intro',
        keyboardOpen: false,
        modalOpen: false,
      );
      expect(
        initialInventory?.elements.where(
              (entry) => entry.tier == 'interactive',
            ) ??
            const <TugboatSceneInventoryEntry>[],
        isEmpty,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 200));
      final tapCenter = tester.getCenter(find.text('Continue'));
      final buildsBeforeDown = controller.debugAnchorTokenMapBuildCount;

      controller.recordPointerDown(tapCenter);
      final buildsAfterDown = controller.debugAnchorTokenMapBuildCount;
      expect(buildsAfterDown, buildsBeforeDown + 1);

      // Simulate navigation in the pointer-up turn. The origin snapshot must
      // remain authoritative after the current route changes.
      controller.debugSetCurrentRoute('/intro_testimony');
      controller.recordPointerUp(tapCenter);
      expect(controller.debugAnchorTokenMapBuildCount, buildsAfterDown);
      await _finishInteraction(tester, controller);

      final interaction = _lastInteraction(controller);
      final fingerprint = interaction.data['targetFingerprint'];
      expect(interaction.data['route'], '/intro');
      expect(fingerprint, isNotEmpty);

      final inventories = controller.session!.events
          .where((event) => event.type == 'scene_inventory')
          .toList();
      final originInventory = inventories.lastWhere(
        (event) => event.data['routeKey'] == '/intro',
      );
      final elements = (originInventory.data['elements'] as List)
          .cast<Map<Object?, Object?>>();
      expect(
        elements.any((entry) => entry['fingerprint'] == fingerprint),
        isTrue,
      );

      final diagnostic = controller.session!.events
          .where((event) => event.type == 'exploration_pre_tap_diagnostic')
          .last;
      expect(diagnostic.data['outcome'], 'captured');
      expect(diagnostic.data['buildMicros'], isA<int>());
      expect(diagnostic.relatedEventId, interaction.id);
    },
  );

  testWidgets(
    'unlinked actionable semantic node falls back to smallest inventory target',
    (tester) async {
      final rootKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: const Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: 20,
                    top: 20,
                    width: 48,
                    height: 48,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rootRender =
          rootKey.currentContext!.findRenderObject()! as RenderBox;
      final bounds = TugboatNormalizedBounds.fromRect(
        const Rect.fromLTWH(20, 20, 48, 48),
        rootRender.size,
      );
      final inventory = TugboatSceneInventory(
        inventoryHash: 'inventory-close',
        routeKey: '/subscriptionPaywall',
        elements: [
          TugboatSceneInventoryEntry(
            fingerprint: 'close-fingerprint',
            canonicalPath: 'Stack#0/IconButton#0',
            widgetType: 'IconButton',
            role: 'button',
            actions: const ['tap'],
            enabled: true,
            boundsNorm: bounds,
            tier: 'interactive',
          ),
        ],
      );
      final map = TugboatViewportSemanticMap(
        routeKey: inventory.routeKey,
        viewport: rootRender.size,
        nodes: [
          TugboatViewportSemanticNode(
            nodeId: 1,
            depth: 4,
            role: 'button',
            actions: const ['tap'],
            enabled: true,
            boundsNorm: bounds,
          ),
        ],
        summary: const {},
        mapHash: 'map-close',
      );

      final resolution = AnchorResolver(rootKey: rootKey)
          .resolveTapOnViewportSemanticMap(
            tapPosition: const Offset(44, 44),
            map: map,
            rootRender: rootRender,
            inventory: inventory,
            enableInventoryFallback: true,
          );

      expect(resolution.status, 'matched_inventory_fallback');
      expect(resolution.linkedFingerprint, 'close-fingerprint');
      expect(resolution.fingerprintConfidence, 'low');
      expect(resolution.linkedCanonicalPath, 'Stack#0/IconButton#0');
    },
  );

  testWidgets('inventory fallback rejects an occluded control', (tester) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: Stack(
              children: [
                const Positioned(
                  left: 20,
                  top: 20,
                  width: 48,
                  height: 48,
                  child: ColoredBox(color: Colors.blue),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {},
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rootRender = rootKey.currentContext!.findRenderObject()! as RenderBox;
    final bounds = TugboatNormalizedBounds.fromRect(
      const Rect.fromLTWH(20, 20, 48, 48),
      rootRender.size,
    );
    final inventory = TugboatSceneInventory(
      inventoryHash: 'inventory-occluded',
      routeKey: '/featurePaywall',
      elements: [
        TugboatSceneInventoryEntry(
          fingerprint: 'occluded-close',
          canonicalPath: 'Stack#0/IconButton#0',
          role: 'button',
          actions: const ['tap'],
          enabled: true,
          boundsNorm: bounds,
          tier: 'interactive',
        ),
      ],
    );
    final map = TugboatViewportSemanticMap(
      routeKey: inventory.routeKey,
      viewport: rootRender.size,
      nodes: [
        TugboatViewportSemanticNode(
          nodeId: 1,
          depth: 2,
          role: 'button',
          actions: const ['tap'],
          enabled: true,
          boundsNorm: bounds,
        ),
      ],
      summary: const {},
      mapHash: 'map-occluded',
    );

    final resolution = AnchorResolver(rootKey: rootKey)
        .resolveTapOnViewportSemanticMap(
          tapPosition: const Offset(44, 44),
          map: map,
          rootRender: rootRender,
          inventory: inventory,
          enableInventoryFallback: true,
        );

    expect(resolution.status, 'matched_actionable');
    expect(resolution.linkedFingerprint, isNull);
    expect(resolution.fingerprintConfidence, isNull);
  });

  testWidgets('outside and opaque surfaces do not fabricate fingerprints', (
    tester,
  ) async {
    final controller = await _mountController(
      tester,
      const Scaffold(
        body: Center(
          child: SizedBox(
            key: Key('texture'),
            width: 100,
            height: 100,
            child: Texture(textureId: 1),
          ),
        ),
      ),
    );
    controller.debugSetCurrentRoute('/platform');

    controller.recordPointerDown(const Offset(-40, -40));
    controller.recordPointerUp(const Offset(-40, -40));
    await _finishInteraction(tester, controller);
    final outside = _lastInteraction(controller);
    expect(outside.data.containsKey('targetFingerprint'), isFalse);
    expect(
      outside.data['targetResolutionFailureReason'],
      'outside_capture_boundary',
    );

    controller.recordPointerDown(const Offset(10, 10));
    controller.recordPointerUp(const Offset(10, 10));
    await _finishInteraction(tester, controller);
    final background = _lastInteraction(controller);
    expect(background.data.containsKey('targetFingerprint'), isFalse);
    expect(
      background.data['targetResolutionFailureReason'],
      'no_scene_inventory',
    );

    final textureCenter = tester.getCenter(find.byKey(const Key('texture')));
    controller.recordPointerDown(textureCenter);
    controller.recordPointerUp(textureCenter);
    await _finishInteraction(tester, controller);
    final opaque = _lastInteraction(controller);
    expect(opaque.data.containsKey('targetFingerprint'), isFalse);
    expect(
      opaque.data['targetResolutionFailureReason'],
      'opaque_platform_view',
    );
  });

  testWidgets(
    'scroll cancel and secondary pointers do not publish tap evidence',
    (tester) async {
      final controller = await _mountController(
        tester,
        Scaffold(
          body: Center(
            child: FilledButton(onPressed: () {}, child: const Text('Go')),
          ),
        ),
      );
      final point = tester.getCenter(find.text('Go'));
      final diagnosticsBefore = controller.session!.events
          .where((event) => event.type == 'exploration_pre_tap_diagnostic')
          .length;
      final buildsBefore = controller.debugAnchorTokenMapBuildCount;

      controller.recordPointerDown(point, pointer: 1);
      final buildsAfterPrimary = controller.debugAnchorTokenMapBuildCount;
      controller.recordPointerDown(point + const Offset(4, 0), pointer: 2);
      expect(buildsAfterPrimary, buildsBefore + 1);
      expect(controller.debugAnchorTokenMapBuildCount, buildsAfterPrimary);

      controller.markPendingClusterGesture(
        pointer: 1,
        gesture: InteractionGesture.pan,
        pointerCount: 2,
      );
      controller.suppressPendingPointer(2);
      controller.recordPointerUp(point + const Offset(20, 0), pointer: 1);
      await _finishInteraction(tester, controller);
      final pan = _lastInteraction(controller);
      expect(pan.data['gesture'], 'pan');
      expect(pan.data.containsKey('targetFingerprint'), isFalse);
      expect(pan.data.containsKey('fingerprintConfidence'), isFalse);
      expect(pan.data.containsKey('targetResolutionFailureReason'), isFalse);

      controller.recordPointerDown(point, pointer: 3);
      controller.recordPointerCancel(point, pointer: 3);
      await _finishInteraction(tester, controller);
      final cancelled = _lastInteraction(controller);
      expect(cancelled.data['gesture'], 'cancelled');
      expect(cancelled.data.containsKey('targetFingerprint'), isFalse);
      expect(cancelled.data.containsKey('fingerprintConfidence'), isFalse);

      final diagnosticCount = controller.session!.events
          .where((event) => event.type == 'exploration_pre_tap_diagnostic')
          .length;
      expect(diagnosticCount, diagnosticsBefore + 2);
    },
  );

  testWidgets('production pointer-down does not use exploration capture', (
    tester,
  ) async {
    const config = TugboatReplayConfig(
      profile: TugboatCaptureProfile.productionLean,
      settleDelay: Duration.zero,
      interactionClaimWindow: Duration.zero,
      enableGlobalPointerCapture: false,
      capturePixelRatio: 1,
    );
    final controller = await _mountController(
      tester,
      Scaffold(
        body: FilledButton(onPressed: () {}, child: const Text('Go')),
      ),
      config: config,
    );
    final point = tester.getCenter(find.text('Go'));
    final buildsBefore = controller.debugAnchorTokenMapBuildCount;

    controller.recordPointerDown(point);
    expect(controller.debugAnchorTokenMapBuildCount, buildsBefore);
    expect(
      controller.session!.events.where(
        (event) => event.type == 'exploration_pre_tap_diagnostic',
      ),
      isEmpty,
    );

    controller.recordPointerUp(point);
    await _finishInteraction(tester, controller);
    final eventTypes = controller.session!.events.map((event) => event.type);
    expect(eventTypes, isNot(contains('scene_inventory')));
    expect(eventTypes, isNot(contains('viewport_semantic_map')));
  });

  testWidgets('dormant profile performs no pointer-down capture work', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.dormant,
            enableGlobalPointerCapture: false,
          ),
          child: child!,
        ),
        home: const Scaffold(body: Text('Dormant')),
      ),
    );
    await tester.pump();

    final controller = TugboatReplay.controller;
    if (controller == null) return;
    final buildsBefore = controller.debugAnchorTokenMapBuildCount;
    controller.recordPointerDown(const Offset(10, 10));
    expect(controller.debugAnchorTokenMapBuildCount, buildsBefore);
    expect(
      controller.session?.events.where(
            (event) => event.type == 'exploration_pre_tap_diagnostic',
          ) ??
          const <TugboatEvent>[],
      isEmpty,
    );
  });
}
