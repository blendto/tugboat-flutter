import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pmkit/src/anchors.dart';

void main() {
  test('PmkitControlInventoryItem serializes fingerprint metadata', () {
    const item = PmkitControlInventoryItem(
      fingerprint: 'fp-1',
      role: 'button',
      widgetType: 'ElevatedButton',
      x: 0.5,
      y: 0.8,
      enabled: true,
      canonicalPath: 'HomeScreen#0/ElevatedButton#0',
      fingerprintConfidence: 'high',
    );
    expect(item.toJson(), {
      'fingerprint': 'fp-1',
      'role': 'button',
      'widgetType': 'ElevatedButton',
      'x': 0.5,
      'y': 0.8,
      'enabled': true,
      'canonicalPath': 'HomeScreen#0/ElevatedButton#0',
      'fingerprintConfidence': 'high',
    });
  });

  testWidgets('buildControlInventory emits stable fingerprints when labels change', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<String> fingerprintForLabel(String label) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: ElevatedButton(
                onPressed: () {},
                child: Text(label),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final inventory = AnchorResolver(rootKey: rootKey).buildControlInventory(
        route: '/home',
        keyboardOpen: false,
        modalOpen: false,
      );
      expect(inventory, isNotEmpty);
      return inventory.first.fingerprint;
    }

    expect(
      await fingerprintForLabel('Generate More'),
      await fingerprintForLabel('Create Variation'),
    );
  });
}
