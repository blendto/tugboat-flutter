import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';

void main() {
  testWidgets('token map builds once per frame across resolver calls', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: Column(
              children: [
                FilledButton(onPressed: () {}, child: const Text('Continue')),
                Expanded(
                  child: ListView(
                    children: [
                      for (var i = 0; i < 40; i++)
                        ListTile(title: Text('Row $i'), onTap: () {}),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final resolver = AnchorResolver(rootKey: rootKey);
    final tap = tester.getCenter(find.text('Continue'));

    final before = resolver.debugTokenMapBuildCount;
    resolver.buildSceneInventory(
      route: '/home',
      keyboardOpen: false,
      modalOpen: false,
    );
    resolver.buildSceneInventory(
      route: '/home',
      keyboardOpen: false,
      modalOpen: false,
    );
    resolver.targetAt(tap, route: '/home');
    resolver.buildTapContext(
      tapPosition: tap,
      route: '/home',
      keyboardOpen: false,
      modalOpen: false,
    );
    final afterSameFrame = resolver.debugTokenMapBuildCount;

    expect(afterSameFrame - before, 1);

    // A bare pump may not fire post-frame callbacks that idle apps schedule;
    // invalidate explicitly and confirm the next call rebuilds.
    resolver.invalidateTokenMapCache();
    resolver.buildSceneInventory(
      route: '/home',
      keyboardOpen: false,
      modalOpen: false,
    );
    expect(resolver.debugTokenMapBuildCount, afterSameFrame + 1);
  });
}
