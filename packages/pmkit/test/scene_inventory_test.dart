import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pmkit/pmkit.dart';
import 'package:pmkit/src/anchors.dart' show AnchorResolver;

class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.onPressed, required this.child});

  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      child: ElevatedButton(onPressed: onPressed, child: child),
    );
  }
}

void main() {
  testWidgets('scene inventory lists actionable elements and images', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    final imageBytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 4, height: 4)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: Column(
              children: [
                FilledButton(onPressed: () {}, child: const Text('Go')),
                SizedBox(
                  width: 120,
                  height: 80,
                  child: Image(
                    image: MemoryImage(imageBytes),
                    fit: BoxFit.cover,
                  ),
                ),
              ],
            ),
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
    expect(inventory!.stateAnchor.signature, inventory.stateSignature);
    expect(inventory.elements.length, greaterThanOrEqualTo(2));
    expect(inventory.inventoryHash, isNotEmpty);
    expect(inventory.stateSignature, isNotEmpty);

    final buttonCenter = tester.getCenter(find.text('Go'));
    final tapAnchor = resolver.targetAt(buttonCenter, route: '/home');
    expect(tapAnchor?.fingerprint, isNotEmpty);

    final interactive = inventory.elements
        .where((entry) => entry.tier == 'interactive')
        .toList();
    expect(interactive, hasLength(1));
    expect(interactive.first.fingerprint, tapAnchor?.fingerprint);
    expect(
      inventory.elements.any(
        (entry) => entry.fingerprint == tapAnchor?.fingerprint,
      ),
      isTrue,
      reason: 'tap fingerprint must match an inventory entry',
    );
    expect(
      interactive.first.boundsNorm.width > 0,
      isTrue,
    );

    final imageEntry = inventory.elements.firstWhere(
      (entry) => entry.tier == 'content' && entry.role == 'display',
    );
    expect(imageEntry.widgetType, contains('Image'));
    expect(imageEntry.fingerprint, isNotEmpty);
  });

  testWidgets('wrapper-heavy button collapses to tap-resolved fingerprint', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: PillButton(
              onPressed: () {},
              child: const Text('Continue'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    final resolver = AnchorResolver(rootKey: rootKey);
    final inventory = resolver.buildSceneInventory(
      route: '/intro',
      keyboardOpen: false,
      modalOpen: false,
    );

    expect(inventory, isNotNull);

    final buttonCenter = tester.getCenter(find.text('Continue'));
    final tapAnchor = resolver.targetAt(buttonCenter, route: '/intro');
    expect(tapAnchor?.fingerprint, isNotEmpty);

    final interactive = inventory!.elements
        .where((entry) => entry.tier == 'interactive')
        .toList();
    expect(interactive, hasLength(1));
    expect(interactive.first.fingerprint, tapAnchor?.fingerprint);
  });

  testWidgets('wrapper-heavy button aliases cover edge tap fingerprints', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: PillButton(
              onPressed: () {},
              child: const Text('Continue'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    final resolver = AnchorResolver(rootKey: rootKey);
    final inventory = resolver.buildSceneInventory(
      route: '/intro',
      keyboardOpen: false,
      modalOpen: false,
    );
    expect(inventory, isNotNull);

    final buttonRect = tester.getRect(find.byType(ElevatedButton));
    final buttonCenter = buttonRect.center;
    final cornerTap = Offset(buttonRect.left + 2, buttonRect.center.dy);

    final centerAnchor = resolver.targetAt(buttonCenter, route: '/intro');
    final edgeAnchor = resolver.targetAt(cornerTap, route: '/intro');
    expect(centerAnchor?.fingerprint, isNotEmpty);
    expect(edgeAnchor?.fingerprint, isNotEmpty);

    final interactive = inventory!.elements
        .where((entry) => entry.tier == 'interactive')
        .single;

    expect(interactive.fingerprint, centerAnchor?.fingerprint);
    expect(
      interactive.fingerprint == edgeAnchor?.fingerprint ||
          interactive.aliases.contains(edgeAnchor?.fingerprint),
      isTrue,
      reason: 'edge tap fingerprint must match primary or alias',
    );
  });

  testWidgets('tap-time inventory matches tap state signature and fingerprint', (
    tester,
  ) async {
    const config = PmkitReplayConfig(
      profile: PmkitCaptureProfile.exploration,
      settleDelay: Duration.zero,
      enableGlobalPointerCapture: false,
      capturePixelRatio: 1.0,
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PmkitReplay.wrapApp(config: config, child: child!),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Go')),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    final controller = PmkitReplay.controller!;
    final tapCenter = tester.getCenter(find.text('Go'));
    controller.recordPointerDown(tapCenter);
    await tester.pump();

    final tapEvents = controller.session!.events
        .where((event) => event.type == 'tap')
        .toList();
    expect(tapEvents, hasLength(1));

    final tapEvent = tapEvents.single;
    final tapFingerprint = tapEvent.targetAnchor?.fingerprint;
    final tapSignature = tapEvent.stateAnchor?.signature;
    expect(tapFingerprint, isNotEmpty);
    expect(tapSignature, isNotEmpty);

    final inventoryEvents = controller.session!.events
        .where((event) => event.type == 'scene_inventory')
        .toList();
    expect(inventoryEvents, isNotEmpty);

    final tapInventory = inventoryEvents.lastWhere(
      (event) => event.stateAnchor?.signature == tapSignature,
    );
    expect(tapInventory.data['stateSignature'], tapSignature);

    final elements = tapInventory.data['elements'] as List<dynamic>;
    expect(
      elements.any(
        (element) =>
            (element as Map<Object?, Object?>)['fingerprint'] ==
            tapFingerprint,
      ),
      isTrue,
      reason: 'tap fingerprint must appear in tap-time inventory',
    );
  });

  testWidgets('tap injection emits inventory when enumeration is empty', (
    tester,
  ) async {
    const config = PmkitReplayConfig(
      profile: PmkitCaptureProfile.exploration,
      settleDelay: Duration.zero,
      enableGlobalPointerCapture: false,
      capturePixelRatio: 1.0,
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PmkitReplay.wrapApp(config: config, child: child!),
        home: Stack(
          children: [
            const Scaffold(body: SizedBox.expand()),
            ModalBarrier(
              dismissible: true,
              onDismiss: () {},
            ),
          ],
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    final controller = PmkitReplay.controller!;
    final tapPoint = const Offset(20, 20);
    controller.recordPointerDown(tapPoint);
    await tester.pump();

    final tapEvent = controller.session!.events
        .where((event) => event.type == 'tap')
        .single;
    final tapFingerprint = tapEvent.targetAnchor?.fingerprint;
    expect(tapFingerprint, isNotEmpty);

    final inventoryEvents = controller.session!.events
        .where((event) => event.type == 'scene_inventory')
        .toList();
    expect(inventoryEvents, isNotEmpty);

    final tapInventory = inventoryEvents.lastWhere(
      (event) => event.stateAnchor?.signature == tapEvent.stateAnchor?.signature,
    );
    final elements = tapInventory.data['elements'] as List<dynamic>;
    expect(
      elements.any(
        (element) =>
            (element as Map<Object?, Object?>)['fingerprint'] == tapFingerprint,
      ),
      isTrue,
    );
  });

  testWidgets('identical taps do not emit duplicate scene inventories', (
    tester,
  ) async {
    const config = PmkitReplayConfig(
      profile: PmkitCaptureProfile.exploration,
      settleDelay: Duration.zero,
      enableGlobalPointerCapture: false,
      capturePixelRatio: 1.0,
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PmkitReplay.wrapApp(config: config, child: child!),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Go')),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    final controller = PmkitReplay.controller!;
    final tapCenter = tester.getCenter(find.text('Go'));
    controller.recordPointerDown(tapCenter);
    await tester.pump();

    final afterFirstTap = controller.session!.events
        .where((event) => event.type == 'scene_inventory')
        .length;

    controller.recordPointerDown(tapCenter);
    await tester.pump();

    final afterSecondTap = controller.session!.events
        .where((event) => event.type == 'scene_inventory')
        .length;
    expect(afterSecondTap, afterFirstTap);
  });

  testWidgets('scene inventory event is deduped per state', (tester) async {
    const config = PmkitReplayConfig(
      profile: PmkitCaptureProfile.exploration,
      settleDelay: Duration.zero,
      enableGlobalPointerCapture: false,
      capturePixelRatio: 1.0,
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PmkitReplay.wrapApp(config: config, child: child!),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Go')),
        ),
      ),
    );

    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    final controller = PmkitReplay.controller!;
    final inventoryEvents = controller.session!.events
        .where((event) => event.type == 'scene_inventory')
        .toList();
    expect(inventoryEvents, isNotEmpty);

    final beforeCount = inventoryEvents.length;
    controller.debugExportSemanticSnapshot();
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    final afterCount = controller.session!.events
        .where((event) => event.type == 'scene_inventory')
        .length;
    expect(afterCount, beforeCount);

    final payload = inventoryEvents.first.data;
    expect(payload['stateSignature'], isA<String>());
    expect(payload['inventoryHash'], isA<String>());
    expect(payload['elements'], isA<List<dynamic>>());
  });
}
