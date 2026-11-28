import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';

// BLE-714: a tap on a switch, checkbox or radio reports that control's role,
// not the `button` of the gesture plumbing inside it, as on Android.
void main() {
  Future<TugboatTargetAnchor?> tapAnchor(
    WidgetTester tester,
    Widget control,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(body: Center(child: control)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final finder = find.byWidget(control);
    return AnchorResolver(
      rootKey: rootKey,
    ).targetAt(tester.getCenter(finder), route: '/r');
  }

  void check(String name, Widget control, String role) {
    testWidgets('$name tap reports role $role', (tester) async {
      final anchor = await tapAnchor(tester, control);
      expect(anchor?.role, role);
      expect(anchor?.enabled, isTrue);
      expect(anchor?.actions, ['tap']);
    });
  }

  void dump(String name, Widget control) {
    testWidgets('$name tap at the control edge', (tester) async {
      final anchor = await tapAnchor(tester, control);
      expect(anchor?.role, isNotNull);
    });
  }

  check('Switch', Switch(value: false, onChanged: (_) {}), 'switch');
  check(
    'SwitchListTile',
    SwitchListTile(value: false, onChanged: (_) {}, title: const Text('A')),
    'switch',
  );
  check(
    'CupertinoSwitch',
    CupertinoSwitch(value: false, onChanged: (_) {}),
    'switch',
  );
  check('Checkbox', Checkbox(value: false, onChanged: (_) {}), 'checkbox');
  check(
    'CheckboxListTile',
    CheckboxListTile(value: false, onChanged: (_) {}, title: const Text('A')),
    'checkbox',
  );
  dump('Switch', Switch(value: false, onChanged: (_) {}));
}
