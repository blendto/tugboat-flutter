import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'widget_capture_wait.dart';

// Blend's step onboarding (device run on a Nokia 5.4, 360x780 logical): a
// PageView of onboarding pages under one named route. "Where do you sell?" is
// a multi-select list of GestureDetector rows; Continue shows only once a row
// is selected and is `Visibility` > `AnimatedOpacity` > `PillButton` >
// `Container` > `Builder` > `SemanticButton` (`Semantics(button)` >
// `ExcludeSemantics`) > `ElevatedButton`, whose onPressed animates the
// PageView (`PageController.nextPage`). Its arrow loops forever (a repeating
// `SlideTransition`), so the page never stops drawing frames.

TugboatReplayConfig onboardingConfig({required bool exploration}) =>
    TugboatReplayConfig(
      enabled: true,
      emitSceneInventory: exploration,
      screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      settleDelay: Duration.zero,
      interactionClaimWindow: Duration.zero,
      capturePixelRatio: 1.0,
    );

class MovingArrow extends StatefulWidget {
  const MovingArrow({super.key});
  @override
  State<MovingArrow> createState() => _MovingArrowState();
}

class _MovingArrowState extends State<MovingArrow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SlideTransition(
    position: Tween(
      begin: const Offset(0.4, 0),
      end: Offset.zero,
    ).animate(_controller),
    child: const Icon(Icons.arrow_forward, size: 18),
  );
}

/// Blend's `SemanticButton`: one semantics node for a Material button.
class SemanticButton extends StatelessWidget {
  const SemanticButton({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: true,
    label: label,
    child: ExcludeSemantics(child: child),
  );
}

/// `PillButton.withMovingArrow`.
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.onTap, required this.loopArrow});
  final VoidCallback onTap;
  final bool loopArrow;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 40, top: 20),
    child: Builder(
      builder: (context) => SemanticButton(
        label: 'Continue',
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(60),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Spacer(),
                const Expanded(flex: 8, child: Center(child: Text('Continue'))),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: loopArrow
                        ? const MovingArrow()
                        : const Icon(Icons.arrow_forward, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class OnboardingPageContainer extends StatelessWidget {
  const OnboardingPageContainer({
    super.key,
    required this.title,
    required this.child,
    required this.showCta,
    required this.onContinue,
    required this.loopArrow,
  });
  final String title;
  final Widget child;
  final bool showCta;
  final VoidCallback onContinue;
  final bool loopArrow;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18).copyWith(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        Flexible(child: child),
        Visibility(
          maintainAnimation: true,
          maintainState: true,
          visible: showCta,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: showCta ? 1 : 0,
            child: PillButton(onTap: onContinue, loopArrow: loopArrow),
          ),
        ),
      ],
    ),
  );
}

class OnboardingListPage extends StatefulWidget {
  const OnboardingListPage({
    super.key,
    required this.title,
    required this.onContinue,
    required this.loopArrow,
  });
  final String title;
  final VoidCallback onContinue;
  final bool loopArrow;
  @override
  State<OnboardingListPage> createState() => _OnboardingListPageState();
}

class _OnboardingListPageState extends State<OnboardingListPage> {
  final selected = <int>{};

  @override
  Widget build(BuildContext context) => OnboardingPageContainer(
    title: widget.title,
    showCta: selected.isNotEmpty,
    onContinue: widget.onContinue,
    loopArrow: widget.loopArrow,
    child: ListView.separated(
      itemCount: 9,
      padding: const EdgeInsets.only(top: 23),
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      physics: const BouncingScrollPhysics(),
      itemBuilder: (context, index) => GestureDetector(
        onTap: () => setState(() {
          if (!selected.remove(index)) selected.add(index);
        }),
        child: Container(
          constraints: const BoxConstraints(minHeight: 80),
          color: const Color(0xff1a1a1a),
          child: Row(
            children: [
              const Icon(Icons.store, size: 24),
              Expanded(child: Text('Option $index')),
              Icon(
                selected.contains(index)
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// `OnboardingSellingOptions`: the page the PageView builds.
class OnboardingSellingOptions extends StatelessWidget {
  const OnboardingSellingOptions({
    super.key,
    required this.index,
    required this.onContinue,
    required this.loopArrow,
  });
  final int index;
  final VoidCallback onContinue;
  final bool loopArrow;

  @override
  Widget build(BuildContext context) => OnboardingListPage(
    title: 'Where do you sell? $index',
    onContinue: onContinue,
    loopArrow: loopArrow,
  );
}

class StepOnboarding extends StatefulWidget {
  const StepOnboarding({
    super.key,
    required this.loopArrow,
    this.pages = 1,
    this.animate = true,
  });
  final bool loopArrow;
  final int pages;

  /// When false, Continue does nothing (no PageView animation).
  final bool animate;
  @override
  State<StepOnboarding> createState() => _StepOnboardingState();
}

class _StepOnboardingState extends State<StepOnboarding> {
  // As on the device, "Where do you sell?" is the PageView's second page.
  final controller = PageController(initialPage: 1);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _next() {
    if (!widget.animate) return;
    controller.nextPage(
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: PageView.builder(
        controller: controller,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: widget.pages + 2,
        itemBuilder: (context, index) => index == 0
            ? const Center(child: Text('First step'))
            : index <= widget.pages
            ? OnboardingSellingOptions(
                index: index,
                onContinue: _next,
                loopArrow: widget.loopArrow,
              )
            : const Center(child: Text('Next step')),
      ),
    ),
  );
}

Future<void> mountOnboarding(
  WidgetTester tester, {
  required TugboatReplayConfig config,
  bool loopArrow = true,
  int pages = 1,
  bool animate = true,
}) async {
  tester.view.physicalSize = const Size(720, 1560);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  TugboatReplay.resetForTest();
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: config, child: child!),
      initialRoute: '/step_onboarding',
      routes: {
        '/step_onboarding': (_) => StepOnboarding(
          loopArrow: loopArrow,
          pages: pages,
          animate: animate,
        ),
      },
    ),
  );
  await waitForTugboatCaptureWork(tester);
}

List<TugboatEvent> onboardingTaps() => [
  for (final e in TugboatReplay.controller!.session!.events)
    if (e.type == 'interaction' && e.data['gesture'] == 'tap') e,
];
