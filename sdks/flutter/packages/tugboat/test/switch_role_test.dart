import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';

// BLE-714: a tap on a switch, checkbox or radio reports that control's role,
// not the `button` of the gesture plumbing inside it, as on Android. A button
// a host app puts inside the row keeps its own role.
void main() {
  Future<TugboatTargetAnchor?> tapAnchor(
    WidgetTester tester,
    Widget control, {
    Finder? at,
  }) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: Center(
              child: RadioGroup<int>(
                groupValue: 0,
                onChanged: (_) {},
                child: control,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AnchorResolver(
      rootKey: rootKey,
    ).targetAt(tester.getCenter(at ?? find.byWidget(control)), route: '/r');
  }

  void check(
    String name,
    Widget control,
    String role, {
    bool enabled = true,
    bool checkEnabled = true,
    Finder? at,
  }) {
    testWidgets('$name tap reports role $role', (tester) async {
      final anchor = await tapAnchor(tester, control, at: at);
      expect(anchor?.role, role);
      if (checkEnabled) {
        expect(anchor?.enabled, enabled);
        expect(anchor?.actions, enabled ? ['tap'] : isEmpty);
      }
    });
  }

  check('Switch', Switch(value: false, onChanged: (_) {}), 'switch');
  check(
    'Switch disabled',
    const Switch(value: false, onChanged: null),
    'switch',
    enabled: false,
  );
  check(
    'SwitchListTile',
    SwitchListTile(value: false, onChanged: (_) {}, title: const Text('A')),
    'switch',
  );
  check(
    'SwitchListTile disabled',
    const SwitchListTile(value: false, onChanged: null, title: Text('A')),
    'switch',
    enabled: false,
  );
  check(
    'the Switch inside a SwitchListTile',
    SwitchListTile(value: false, onChanged: (_) {}, title: const Text('A')),
    'switch',
    at: find.byType(Switch),
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
  check('Radio', const Radio<int>(value: 0), 'radio', checkEnabled: false);
  check(
    'RadioListTile',
    const RadioListTile<int>(value: 0, title: Text('A')),
    'radio',
    checkEnabled: false,
  );

  // A control of the host app inside the row is not the toggle's plumbing.
  check(
    'a TextButton in a SwitchListTile',
    SwitchListTile(
      value: false,
      onChanged: (_) {},
      title: const Text('A'),
      secondary: TextButton(onPressed: () {}, child: const Text('Go')),
    ),
    'button',
    at: find.text('Go'),
  );
  check(
    'an InkWell in a CheckboxListTile',
    CheckboxListTile(
      value: false,
      onChanged: (_) {},
      title: const Text('A'),
      secondary: InkWell(onTap: () {}, child: const Text('Go')),
    ),
    'button',
    at: find.text('Go'),
  );
  check(
    'a GestureDetector in a CheckboxListTile',
    CheckboxListTile(
      value: false,
      onChanged: (_) {},
      title: const Text('A'),
      secondary: GestureDetector(onTap: () {}, child: const Text('Go')),
    ),
    'button',
    at: find.text('Go'),
  );
  check(
    'an IconButton in a disabled SwitchListTile',
    SwitchListTile(
      value: false,
      onChanged: null,
      title: const Text('A'),
      secondary: IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
    ),
    'button',
    at: find.byType(IconButton),
  );
}
