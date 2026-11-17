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

const _rowAtPageViewCentre =
    '/OnboardingListPage#0/OnboardingPageContainer#0/ListView#0/'
    'Scrollable#0/[item:0]/StretchEffect#0/RawGestureDetector#0/[item:3]';

void main() {
  tearDown(TugboatReplay.resetForTest);

  group('diagnosis before the fix', () {
    testWidgets('exploration re-anchors the tap to the row at the PageView '
        'centre', (tester) async {
      final tap = await selectThenContinue(tester, exploration: true);
      expect(_path(tap), endsWith(_rowAtPageViewCentre));
      expect(tap.data['fingerprintSource'], 'pointerDown');
      final rowEntries = [
        for (final e in TugboatReplay.controller!.session!.events)
          if (e.type == 'scene_inventory')
            for (final entry
                in (e.data['elements']! as List).cast<Map<String, Object?>>())
              if (entry['fingerprint'] == _fingerprint(tap)) entry,
      ];
      expect(
        rowEntries.any(
          (entry) =>
              (entry['aliases'] as List?)?.contains(_pageViewScrollable) ??
              false,
        ),
        isTrue,
      );
    });

    testWidgets('production gives the PageView Scrollable', (tester) async {
      final tap = await selectThenContinue(tester, exploration: false);
      expect(_fingerprint(tap), _pageViewScrollable);
      expect(_path(tap), 'StepOnboarding#0/Scaffold#0/PageView#0/Scrollable#0');
    });

    testWidgets('production with a Continue that does not animate gives the '
        'same row as exploration', (tester) async {
      final tap = await selectThenContinue(
        tester,
        exploration: false,
        animate: false,
      );
      expect(_path(tap), endsWith(_rowAtPageViewCentre));
    });
  });

  testWidgets(
    'the Continue tap resolves to the button, the same in both modes',
    (tester) async {
      final exploration = await selectThenContinue(tester, exploration: true);
      final production = await selectThenContinue(tester, exploration: false);

      expect(_path(exploration), endsWith('/PillButton#0'));
      expect(exploration.targetAnchor?.role, 'button');
      expect(_fingerprint(production), _fingerprint(exploration));
      expect(_path(production), _path(exploration));
    },
    skip: true, // P1: fails until the hidden-control identity fix (step 2).
  );
}
