import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// The Blend onboarding frequency grid: a PageView (NeverScrollableScrollPhysics)
// of grid pages whose GestureDetector tiles call `PageController.nextPage`.
// The animated scroll makes the PageView's Scrollable ignore pointers at
// once, so production, which reads the tap after the app's onTap, hit only
// the Scrollable; exploration, which resolves at pointer-down, hit the tile.
// The first grid page agreed: it jumps (no animation, no IgnorePointer).

TugboatReplayConfig _config({required bool exploration}) => TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: exploration,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

class FrequencyGridPage extends StatelessWidget {
  const FrequencyGridPage({super.key, required this.onPick});
  final void Function(BuildContext context) onPick;

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    physics: const BouncingScrollPhysics(),
    itemCount: 4,
    // As in Blend: the grid fits and its BouncingScrollPhysics adds no drag
    // recognizer, so the tap wins its arena at pointer-down and onTap runs
    // before the SDK's global pointer route.
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      childAspectRatio: 2,
    ),
    itemBuilder: (context, index) => GestureDetector(
      onTap: () => onPick(context),
      child: Container(
        margin: const EdgeInsets.all(8),
        color: const Color(0xff1a1a1a),
        child: Center(child: Text('Option $index')),
      ),
    ),
  );
}

class StepOnboarding extends StatefulWidget {
  const StepOnboarding({super.key, required this.animate});
  final bool animate;
  @override
  State<StepOnboarding> createState() => _StepOnboardingState();
}

class _StepOnboardingState extends State<StepOnboarding> {
  final controller = PageController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _next(BuildContext context) => widget.animate
      ? controller.nextPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
        )
      : controller.jumpToPage(1);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageView(
      controller: controller,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        FrequencyGridPage(onPick: _next),
        const Center(child: Text('Next step')),
      ],
    ),
  );
}

Future<TugboatEvent> _tapOption(
  WidgetTester tester, {
  required bool exploration,
  required bool animate,
}) async {
  await tester.pumpWidget(const SizedBox());
  TugboatReplay.resetForTest();
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) => TugboatReplay.wrapApp(
        config: _config(exploration: exploration),
        child: child!,
      ),
      initialRoute: '/step_onboarding',
      routes: {'/step_onboarding': (_) => StepOnboarding(animate: animate)},
    ),
  );
  await waitForTugboatCaptureWork(tester);
  await tester.tap(find.text('Option 1'));
  await tester.pumpAndSettle();
  await waitForTugboatCaptureWork(tester);
  expect(find.text('Next step'), findsOneWidget);
  return TugboatReplay.controller!.session!.events.lastWhere(
    (e) => e.type == 'interaction' && e.data['gesture'] == 'tap',
  );
}

String? _path(TugboatEvent tap) => tap.targetAnchor?.canonicalPath;

String? _fingerprint(TugboatEvent tap) => tap.targetAnchor?.fingerprint;

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a tile whose onTap animates the PageView resolves to the tile '
      'in both modes', (tester) async {
    final exploration = await _tapOption(
      tester,
      exploration: true,
      animate: true,
    );
    final production = await _tapOption(
      tester,
      exploration: false,
      animate: true,
    );

    expect(_path(exploration), contains('/GridView#0/Scrollable#0/'));
    expect(_path(exploration), endsWith('[item:1]'));
    expect(_fingerprint(production), _fingerprint(exploration));
    expect(_fingerprint(production), isNotNull);
    expect(_path(production), _path(exploration));
  });

  testWidgets('a jumping tile already agreed and is unchanged', (tester) async {
    final exploration = await _tapOption(
      tester,
      exploration: true,
      animate: false,
    );
    final production = await _tapOption(
      tester,
      exploration: false,
      animate: false,
    );

    expect(_fingerprint(production), _fingerprint(exploration));
    expect(_fingerprint(production), isNotNull);
    expect(_path(production), contains('/GridView#0/Scrollable#0/'));
    expect(_path(production), endsWith('[item:1]'));
  });

  testWidgets('a tap on a scrollable outside any control keeps the '
      'scrollable', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _config(exploration: false),
          child: child!,
        ),
        initialRoute: '/list',
        routes: {
          '/list': (_) => Scaffold(
            body: ListView(
              children: [
                for (var i = 0; i < 3; i++)
                  SizedBox(height: 80, child: Text('Row $i')),
              ],
            ),
          ),
        },
      ),
    );
    await waitForTugboatCaptureWork(tester);
    await tester.tap(find.text('Row 1'));
    await waitForTugboatCaptureWork(tester);

    final tap = TugboatReplay.controller!.session!.events.lastWhere(
      (e) => e.type == 'interaction' && e.data['gesture'] == 'tap',
    );
    expect(_path(tap), 'Scaffold#0/ListView#0/Scrollable#0');
  });
}
