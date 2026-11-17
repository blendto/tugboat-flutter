import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/onboarding_fixture.dart';
import 'helpers/widget_capture_wait.dart';

// Device run on a Nokia 5.4: the "Where do you sell?" Continue tap (yNorm
// 0.916) resolved to the Etsy row in exploration and to the PageView's
// Scrollable (4247d59bfaeb41d9) in production. The fixture reproduces both.
//
// Diagnosis: the Continue is a sole control hidden under `ExcludeSemantics`
// inside the PageView. A hit on it maps to the first retained widget above
// the excluded subtree (the `PillButton` margin `Padding`), and the identity
// walk climbs from there to the nearest control: the PageView's Scrollable.
// So the button has no identity of its own in either mode (recognition), and
// the 0.11.0 inventory listing of excluded-semantics controls leaves it out
// because that tap "resolves to a control with a role".
// - Exploration: the pre-tap inventory lists the PageView Scrollable's
//   fingerprint as an alias of the row at the PageView's centre (that entry's
//   centre hit lands on the row), and alias normalisation re-anchors the tap
//   to that row, still labelled `pointerDown`.
// - Production (animating Continue): the pointer-up hit stops at the
//   Scrollable (IgnorePointer while `nextPage` runs). The pointer-down rule is
//   consulted, but the pressed path resolves to the same Scrollable, so it
//   has nothing inside it to prefer. With a Continue that does not animate,
//   production re-anchors to the same row as exploration: the miss is
//   recognition, not the pointer-down rule.

const _pageViewScrollable = '4247d59bfaeb41d9';

Future<TugboatEvent> selectThenContinue(
  WidgetTester tester, {
  required bool exploration,
  bool animate = true,
}) async {
  await mountOnboarding(
    tester,
    config: onboardingConfig(exploration: exploration),
    animate: animate,
  );
  await tester.tap(find.text('Option 0'));
  await tester.pump(const Duration(milliseconds: 500));
  await waitForTugboatCaptureWork(tester);
  final continueButton = find.byType(ElevatedButton);
  expect(continueButton, findsOneWidget);
  final center = tester.getCenter(continueButton);
  // As on the device (yNorm 0.916): Continue sits near the bottom.
  expect(center.dy / 780, greaterThan(0.85));
  await tester.tapAt(center);
  await tester.pump(const Duration(milliseconds: 400));
  await waitForTugboatCaptureWork(tester);
  if (animate) expect(find.text('Next step'), findsOneWidget);
  return onboardingTaps().last;
}

String? _path(TugboatEvent tap) => tap.targetAnchor?.canonicalPath;

String? _fingerprint(TugboatEvent tap) => tap.targetAnchor?.fingerprint;

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('the Continue tap resolves to the button, the same in both '
      'modes', (tester) async {
    final exploration = await selectThenContinue(tester, exploration: true);
    final inventories = [
      for (final e in TugboatReplay.controller!.session!.events)
        if (e.type == 'scene_inventory') e,
    ];
    final production = await selectThenContinue(tester, exploration: false);

    expect(_path(exploration), endsWith('/PillButton#0'));
    expect(_path(exploration), contains('/[item:1]/OnboardingListPage#0/'));
    expect(exploration.targetAnchor?.role, 'button');
    expect(exploration.targetAnchor?.widgetType, 'ElevatedButton');
    expect(exploration.data['fingerprintSource'], 'pointerDown');
    expect(_fingerprint(exploration), isNot(_pageViewScrollable));
    expect(_fingerprint(production), _fingerprint(exploration));
    expect(_path(production), _path(exploration));

    // An exploration inventory lists Continue with the tap's fingerprint
    // and its own box, so the tap joins it.
    final entries = [
      for (final inventory in inventories)
        for (final e
            in (inventory.data['elements']! as List)
                .cast<Map<String, Object?>>())
          if (e['fingerprint'] == _fingerprint(exploration))
            (trigger: inventory.data['trigger'], entry: e),
    ];
    expect(entries, isNotEmpty);
    expect(entries.first.trigger, 'tap');
    final entry = entries.first.entry;
    expect(entry['role'], 'button');
    expect(entry['widgetType'], 'ElevatedButton');
    final box = (entry['boundsNorm']! as Map).cast<String, Object?>();
    expect(box['top']! as double, greaterThan(0.8));
  });

  testWidgets('a Continue that does not animate also resolves to the button '
      'in production', (tester) async {
    final animated = await selectThenContinue(tester, exploration: false);
    final still = await selectThenContinue(
      tester,
      exploration: false,
      animate: false,
    );
    expect(_path(still), endsWith('/PillButton#0'));
    expect(_fingerprint(still), _fingerprint(animated));
  });

  _boundaryTests();
}

/// A list of rows and one more row holding [cta], all in one ListView.
Widget _listWith(Widget cta) => Scaffold(
  body: ListView(
    children: [
      for (var i = 0; i < 3; i++)
        GestureDetector(
          onTap: () {},
          child: SizedBox(height: 80, child: Text('Row $i')),
        ),
      cta,
    ],
  ),
);

Widget _hidden(String label) => SemanticButton(
  label: label,
  child: ElevatedButton(onPressed: () {}, child: Text(label)),
);

class _HiddenInList extends StatelessWidget {
  const _HiddenInList();
  @override
  Widget build(BuildContext context) =>
      _listWith(PillButton(onTap: () {}, loopArrow: false));
}

class _HiddenInInkWell extends StatelessWidget {
  const _HiddenInInkWell();
  @override
  Widget build(BuildContext context) =>
      _listWith(InkWell(onTap: () {}, child: _hidden('Inside')));
}

class _TwoHidden extends StatelessWidget {
  const _TwoHidden();
  @override
  Widget build(BuildContext context) => _listWith(
    Semantics(
      label: 'Pair',
      child: ExcludeSemantics(
        child: Row(
          children: [
            ElevatedButton(onPressed: () {}, child: const Text('A')),
            ElevatedButton(onPressed: () {}, child: const Text('B')),
          ],
        ),
      ),
    ),
  );
}

Future<TugboatTargetAnchor?> _tapIn(
  WidgetTester tester,
  Widget page,
  Finder target, {
  required bool exploration,
}) async {
  await tester.pumpWidget(const SizedBox());
  TugboatReplay.resetForTest();
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) => TugboatReplay.wrapApp(
        config: onboardingConfig(exploration: exploration),
        child: child!,
      ),
      initialRoute: '/list',
      routes: {'/list': (_) => page},
    ),
  );
  await waitForTugboatCaptureWork(tester);
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 300));
  await waitForTugboatCaptureWork(tester);
  return onboardingTaps().last.targetAnchor;
}

void _boundaryTests() {
  // Before the fix this tap was the ListView's Scrollable in production and
  // unresolved in exploration.
  testWidgets('a sole hidden button in a ListView is the button in both '
      'modes, not the ListView', (tester) async {
    final finder = find.byType(ElevatedButton);
    final exploration = await _tapIn(
      tester,
      const _HiddenInList(),
      finder,
      exploration: true,
    );
    final production = await _tapIn(
      tester,
      const _HiddenInList(),
      finder,
      exploration: false,
    );
    // A list row takes the row position as its token.
    expect(
      exploration?.canonicalPath,
      endsWith(
        '/Scrollable#0/[item:0]/'
        'StretchEffect#0/RawGestureDetector#0/[item:3]',
      ),
    );
    expect(exploration?.role, 'button');
    expect(exploration?.widgetType, 'ElevatedButton');
    expect(production?.fingerprint, exploration?.fingerprint);
  });

  // Unchanged by the fix (checked against the code before it).
  testWidgets('a hidden button inside an InkWell keeps the InkWell', (
    tester,
  ) async {
    final finder = find.text('Inside');
    final exploration = await _tapIn(
      tester,
      const _HiddenInInkWell(),
      finder,
      exploration: true,
    );
    final production = await _tapIn(
      tester,
      const _HiddenInInkWell(),
      finder,
      exploration: false,
    );
    expect(exploration?.canonicalPath, endsWith('/[item:3]'));
    expect(exploration?.widgetType, 'MouseRegion');
    expect(production?.fingerprint, exploration?.fingerprint);
  });

  // Unchanged by the fix: a fork above the first hidden control names
  // nothing, so production keeps the ListView and exploration stays
  // unresolved, as before.
  testWidgets('two buttons under one ExcludeSemantics in a ListView are not '
      'named', (tester) async {
    final finder = find.text('A');
    final exploration = await _tapIn(
      tester,
      const _TwoHidden(),
      finder,
      exploration: true,
    );
    final production = await _tapIn(
      tester,
      const _TwoHidden(),
      finder,
      exploration: false,
    );
    expect(exploration, isNull);
    expect(production?.canonicalPath, 'Scaffold#0/ListView#0/Scrollable#0');
  });
}
