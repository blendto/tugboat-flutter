import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// A host app's intro screen Continue CTA: a PillButton whose SemanticButton
// replaces the button's semantics (`Semantics(identifier, label) >
// ExcludeSemantics > ElevatedButton`), faded in after a delay under
// `IgnorePointer(ignoring: !showCta)` + `AnimatedOpacity`. Production taps
// resolved it to the PillButton path; exploration listed it in no inventory
// and its taps failed with `no_target_at_point`.

TugboatReplayConfig _config({required bool exploration}) => TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: exploration,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

/// `SemanticButton`: one semantics node for a Material button.
class SemanticButton extends StatelessWidget {
  const SemanticButton({
    super.key,
    required this.child,
    this.label,
    this.identifier,
  });
  final Widget child;
  final String? label;
  final String? identifier;

  @override
  Widget build(BuildContext context) {
    if (label == null && identifier == null) return child;
    return Semantics(
      button: true,
      enabled: true,
      label: label,
      identifier: identifier,
      child: ExcludeSemantics(child: child),
    );
  }
}

/// `PillButton`: margin, then a SemanticButton around an ElevatedButton.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.onTap,
    required this.text,
    this.semanticsIdentifier,
  });
  final VoidCallback onTap;
  final String text;
  final String? semanticsIdentifier;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(25),
    child: Builder(
      builder: (context) => SemanticButton(
        label: text,
        identifier: semanticsIdentifier,
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(minimumSize: const Size(10, 60)),
          child: Text(text),
        ),
      ),
    ),
  );
}

class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});
  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  bool showCta = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(seconds: 5), () {
      if (mounted) setState(() => showCta = true);
    });
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned(top: 80, left: 0, right: 0, child: Text('Intro title')),
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: IgnorePointer(
          ignoring: !showCta,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: showCta ? 1 : 0,
            child: SafeArea(
              child: PillButton(
                key: const Key('intro_screen_next'),
                semanticsIdentifier: 'intro_screen_next',
                text: 'Continue',
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  required bool exploration,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) => TugboatReplay.wrapApp(
        config: _config(exploration: exploration),
        child: child!,
      ),
      initialRoute: '/intro',
      routes: {'/intro': (_) => Scaffold(body: page)},
    ),
  );
  await waitForTugboatCaptureWork(tester);
}

/// Lets the CTA timer fire, its fade run, and the settled watch go quiet.
Future<void> _waitForCta(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
  }
  await waitForTugboatCaptureWork(tester);
}

List<Map<String, Object?>> _inventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

List<Map<String, Object?>> _entries(Map<String, Object?> inventory) =>
    (inventory['elements']! as List).cast<Map<String, Object?>>();

Map<String, Object?> _tap() => TugboatReplay.controller!.session!.events
    .lastWhere((e) => e.type == 'interaction' && e.data['gesture'] == 'tap')
    .data;

Map<String, Object?>? _ctaEntry() {
  for (final inventory in _inventories().reversed) {
    for (final entry in _entries(inventory)) {
      if ((entry['canonicalPath']! as String).endsWith('PillButton#0')) {
        return entry;
      }
    }
  }
  return null;
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('exploration lists the CTA once it shows and both modes give '
      'its tap one fingerprint', (tester) async {
    await _mount(tester, const IntroScreen(), exploration: true);
    expect(_ctaEntry(), isNull, reason: 'hidden at opacity 0');

    await _waitForCta(tester);
    final settled = _inventories().where((i) => i['trigger'] == 'settled');
    expect(
      settled.expand(_entries).map((e) => e['canonicalPath']),
      contains('Scaffold#0/IntroScreen#0/PillButton#0'),
      reason: 'the settled re-sample catches the CTA appearing',
    );
    final entry = _ctaEntry()!;
    expect(entry['role'], 'button');
    expect(entry['actions'], ['tap']);

    await tester.tap(find.text('Continue'));
    await waitForTugboatCaptureWork(tester);
    final exploration = _tap();
    expect(exploration['targetResolutionFailureReason'], isNull);
    expect(exploration['targetFingerprint'], entry['fingerprint']);
    expect(exploration['fingerprintSource'], 'pointerDown');
    expect(exploration['routeKey'], '/intro');

    await tester.pumpWidget(const SizedBox());
    TugboatReplay.resetForTest();
    await _mount(tester, const IntroScreen(), exploration: false);
    await _waitForCta(tester);
    await tester.tap(find.text('Continue'));
    await waitForTugboatCaptureWork(tester);
    expect(_tap()['targetFingerprint'], entry['fingerprint']);
  });

  testWidgets('a wrapper hiding two controls (also in a list), or one that '
      'ignores pointers, is not listed', (tester) async {
    await _mount(
      tester,
      Column(
        children: [
          Container(
            margin: const EdgeInsets.all(8),
            child: ExcludeSemantics(
              child: Row(
                children: [
                  ElevatedButton(onPressed: () {}, child: const Text('A')),
                  ElevatedButton(onPressed: () {}, child: const Text('B')),
                ],
              ),
            ),
          ),
          const PillGroup(),
          const HiddenList(),
          PillButton(onTap: () {}, text: 'Solo'),
        ],
      ),
      exploration: true,
    );
    await tester.pump(const Duration(seconds: 1));
    await waitForTugboatCaptureWork(tester);

    // Entries for hidden controls name a path above the control.
    final hidden = {
      for (final entry in _inventories().expand(_entries))
        if ((entry['role'] == 'button' || entry['role'] == 'scrollable') &&
            !(entry['canonicalPath']! as String).contains('ElevatedButton'))
          entry['canonicalPath'],
    };
    expect(hidden, {'Scaffold#0/PillButton#0'});
  });
}

/// A replaced-semantics button that ignores pointers is not a control.
class PillGroup extends StatelessWidget {
  const PillGroup({super.key});
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SemanticButton(
      label: 'Busy',
      child: ElevatedButton(onPressed: () {}, child: const Text('Busy')),
    ),
  );
}

/// A list of two buttons under one `ExcludeSemantics`: the list is not the
/// hidden control, its two buttons are, so nothing is listed.
class HiddenList extends StatelessWidget {
  const HiddenList({super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 120,
    child: ExcludeSemantics(
      child: ListView(
        children: [
          ElevatedButton(onPressed: () {}, child: const Text('L1')),
          ElevatedButton(onPressed: () {}, child: const Text('L2')),
        ],
      ),
    ),
  );
}
