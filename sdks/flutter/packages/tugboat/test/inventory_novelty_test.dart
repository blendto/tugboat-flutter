import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tugboat/tugboat.dart';

import 'helpers/onboarding_fixture.dart';
import 'helpers/widget_capture_wait.dart';

const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

final _imageBytes = Uint8List.fromList(
  img.encodePng(img.Image(width: 4, height: 4)),
);

/// Blend's Logo Maker onboarding (`/logoGenerator/onboarding`): a 1200 s
/// `AnimationController` whose listener `jumpTo`s a horizontal `ListView`
/// of 40 images under `IgnorePointer`, every frame.
class LogoOnboardingMarquee extends StatefulWidget {
  const LogoOnboardingMarquee({super.key});
  @override
  State<LogoOnboardingMarquee> createState() => _LogoOnboardingMarqueeState();
}

class _LogoOnboardingMarqueeState extends State<LogoOnboardingMarquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1200),
  );
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _animation
      ..addListener(() {
        if (_scroll.hasClients && _scroll.position.hasContentDimensions) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent * _animation.value);
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _animation.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('Design a logo'),
        SizedBox(
          height: 300,
          child: IgnorePointer(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              controller: _scroll,
              itemCount: 40,
              itemBuilder: (context, index) => Row(
                children: [
                  Image(
                    image: MemoryImage(_imageBytes),
                    width: 160,
                    height: 300,
                    fit: BoxFit.cover,
                  ),
                  const SizedBox(width: 5),
                ],
              ),
            ),
          ),
        ),
        ElevatedButton(onPressed: () {}, child: const Text('Create logo')),
      ],
    ),
  );
}

TugboatReplayController get _controller => TugboatReplay.controller!;

List<Map<String, Object?>> _inventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

Future<void> _mountNamed(
  WidgetTester tester,
  String route,
  WidgetBuilder page, {
  TugboatReplayConfig config = _exploration,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: config, child: child!),
      initialRoute: route,
      routes: {route: page},
    ),
  );
  await waitForTugboatCaptureWork(tester);
}

/// Pumps [total] of fake time in 50 ms frames.
Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 50);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += step) {
    await tester.pump(step);
  }
}

/// An auto-advancing carousel: a `PageView.builder` of [itemCount] images
/// whose page moves on every [period] (`nextPage`, like Blend's marquee but
/// paged).
class _Carousel extends StatefulWidget {
  const _Carousel({required this.itemCount, required this.period});
  final int itemCount;
  final Duration period;
  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  final _pages = PageController();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.period, (_) {
      final page = (_pages.page ?? 0).round();
      if (page + 1 >= widget.itemCount) {
        _pages.jumpToPage(0);
      } else {
        _pages.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.ease,
        );
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        SizedBox(
          height: 300,
          child: PageView.builder(
            controller: _pages,
            itemCount: widget.itemCount,
            itemBuilder: (context, index) =>
                Image(image: MemoryImage(_imageBytes), width: 300, height: 300),
          ),
        ),
        ElevatedButton(onPressed: () {}, child: const Text('Start')),
      ],
    ),
  );
}

List<Map<String, Object?>> _elements(Map<String, Object?> inventory) => [
  for (final e in inventory['elements']! as List) (e as Map).cast(),
];

bool _lists(Map<String, Object?> inventory, bool Function(String path) test) =>
    _elements(inventory).any((e) => test(e['canonicalPath']! as String));

bool _isContinue(String path) => path.endsWith('/PillButton#0');

/// A page that shows a skeleton until [load] completes ([spinner]: only a
/// spinner), then a header, two buttons and an image.
class _SkeletonThenContent extends StatelessWidget {
  const _SkeletonThenContent({required this.load, this.spinner = false});
  final Future<void> load;
  final bool spinner;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FutureBuilder<void>(
      future: load,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          return Column(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Buy')),
              FilledButton(onPressed: () {}, child: const Text('Share')),
              Image(image: MemoryImage(_imageBytes), width: 200, height: 200),
            ],
          );
        }
        if (spinner) {
          return const Center(child: CircularProgressIndicator());
        }
        return const ShimmerList();
      },
    ),
  );
}

/// A skeleton: disabled placeholder buttons under a `Shimmer`-named widget.
class ShimmerList extends StatelessWidget {
  const ShimmerList({super.key});
  @override
  Widget build(BuildContext context) => const Column(
    children: [
      FilledButton(onPressed: null, child: SizedBox(width: 120)),
      FilledButton(onPressed: null, child: SizedBox(width: 120)),
    ],
  );
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('an auto-scrolling marquee emits nothing once every item '
      'template has been sent', (tester) async {
    await _mountNamed(
      tester,
      '/logoGenerator/onboarding',
      (_) => const LogoOnboardingMarquee(),
    );
    final first = _inventories();
    await _pumpFor(tester, const Duration(seconds: 30));
    final all = _inventories();
    // Before: 340 inventories in these 30 s (scroll start and end of every
    // `jumpTo`). Now the first inventory lists every template (an image
    // in a list row, the title, the button) and nothing after it is new.
    expect(first, hasLength(1));
    expect(first.single['trigger'], 'initial');
    expect(all, hasLength(1));
    expect(_controller.debugSettledSampleCount, inInclusiveRange(1, 12));
  });

  // The cost of keeping a PageView's page position: each page index is a
  // new path, so an auto-advancing carousel sends one re-sample per page it
  // has not shown yet in the visit, and nothing once it loops.
  for (final itemCount in [4, 1000]) {
    testWidgets('an auto-advancing PageView of $itemCount pages sends one '
        'inventory per page not yet shown', (tester) async {
      await _mountNamed(
        tester,
        '/carousel',
        (_) =>
            _Carousel(itemCount: itemCount, period: const Duration(seconds: 2)),
      );
      await _pumpFor(tester, const Duration(seconds: 30));
      await waitForTugboatCaptureWork(tester);
      final all = _inventories();
      // ignore: avoid_print
      print(
        'CAROUSEL $itemCount ${all.length} '
        '${all.map((e) => e['trigger']).toList()}',
      );
      // 30 s at one page every 2 s: 15 page moves. Measured: 4 pages send 4
      // (the first, then each new page once), 1000 pages send 15.
      expect(all.length, itemCount == 4 ? 4 : 15);
      expect(all.first['trigger'], 'initial');
      expect(all.skip(1).map((e) => e['trigger']), everyElement('scroll'));
    });
  }

  testWidgets('a Continue revealed by a row tap is listed once, as tap', (
    tester,
  ) async {
    await mountOnboarding(tester, config: onboardingConfig(exploration: true));
    await tester.tap(find.text('Option 0'));
    // The tap's own inventories, then the reveal. The arrow loops for ever:
    // the forced check samples after 2 s.
    await waitForTugboatCaptureWork(tester);
    await _pumpFor(tester, const Duration(seconds: 6));
    await waitForTugboatCaptureWork(tester);

    final withContinue = [
      for (final inventory in _inventories())
        if (_lists(inventory, _isContinue)) inventory,
    ];
    expect(withContinue, hasLength(1));
    expect(withContinue.single['trigger'], 'tap');
  });

  // Seven pages share one route key. Continue shows 1 s after a row is
  // picked, after the tap's own inventories, so only a re-sample lists it
  // before it is tapped. The old cap (five settled inventories per route key
  // per session) left pages 6 and 7 out.
  testWidgets('every page of one PageView route gets its Continue inventory '
      'before Continue is tapped', (tester) async {
    const pages = 7;
    await mountOnboarding(
      tester,
      config: onboardingConfig(exploration: true),
      pages: pages,
      loopArrow: false,
      revealDelay: const Duration(seconds: 3),
    );
    final missing = <int>[];
    for (var page = 1; page <= pages; page++) {
      await tester.tap(find.text('Option 0').hitTestable());
      // The tap's own inventories finish before Continue shows.
      await waitForTugboatCaptureWork(tester);
      await _pumpFor(tester, const Duration(milliseconds: 5000));
      await waitForTugboatCaptureWork(tester);
      final listed = _inventories().any(
        (inventory) => _lists(
          inventory,
          (path) =>
              _isContinue(path) &&
              path.contains('/[item:$page]/OnboardingListPage#0/'),
        ),
      );
      if (!listed) missing.add(page);
      await tester.tap(find.byType(ElevatedButton).hitTestable());
      await _pumpFor(tester, const Duration(milliseconds: 600));
      await waitForTugboatCaptureWork(tester);
    }
    expect(find.text('Next step'), findsOneWidget);
    expect(missing, isEmpty);
  });

  for (final spinner in [false, true]) {
    testWidgets('loaded content replacing a '
        '${spinner ? 'spinner' : 'skeleton'} emits as settled', (tester) async {
      final load = Completer<void>();
      await _mountNamed(
        tester,
        '/shop',
        (_) => _SkeletonThenContent(load: load.future, spinner: spinner),
      );
      await _pumpFor(tester, const Duration(seconds: 1));
      load.complete();
      await _pumpFor(tester, const Duration(seconds: 3));
      await waitForTugboatCaptureWork(tester);

      final settled = _inventories().where((e) => e['trigger'] == 'settled');
      expect(settled, hasLength(1));
      expect(_elements(settled.single), hasLength(3));
    });
  }

  testWidgets('a static page emits nothing after its first inventory', (
    tester,
  ) async {
    await _mountNamed(
      tester,
      '/static',
      (_) => Scaffold(
        body: Column(
          children: [
            FilledButton(onPressed: () {}, child: const Text('One')),
            const Text('Two'),
          ],
        ),
      ),
    );
    await _pumpFor(tester, const Duration(seconds: 20));
    await waitForTugboatCaptureWork(tester);
    expect(_inventories(), hasLength(1));
    expect(_controller.debugSettledSampleCount, 0);
  });
}
