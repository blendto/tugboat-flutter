import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

/// Exploration with the settled re-sample at its default (on).
const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

const _resampleOff = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  resampleSettledInventory: false,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

const _production = TugboatReplayConfig(
  enabled: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

/// Viewport semantic maps only: inventories are built but never emitted.
const _semanticMapOnly = TugboatReplayConfig(
  enabled: true,
  emitViewportSemanticMap: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

TugboatReplayController get _controller => TugboatReplay.controller!;

Future<void> _mount(
  WidgetTester tester,
  Widget home,
  TugboatReplayConfig config,
) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: config, child: child!),
      home: home,
    ),
  );
  await waitForTugboatCaptureWork(tester);
}

/// Pumps [total] of fake time in steps, then lets capture work finish. A pump
/// draws a frame only when something is dirty, and each drawn frame counts as
/// layout activity for the settled watch, so an idle page lets the quiet
/// window elapse.
Future<void> _advance(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 50);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += step) {
    await tester.pump(step);
  }
  await waitForTugboatCaptureWork(tester);
}

List<Map<String, Object?>> _inventories() => [
  for (final event in _controller.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

List<Map<String, Object?>> _settled() =>
    _inventories().where((inv) => inv['trigger'] == 'settled').toList();

List<Map<String, Object?>> _elements(Map<String, Object?> inventory) => [
  for (final e in inventory['elements']! as List) (e as Map).cast(),
];

/// The structure a consumer sees, minus the fields this change added.
String _structure(Map<String, Object?> inventory) => jsonEncode({
  for (final entry in inventory.entries)
    if (entry.key != 'trigger' && entry.key != 'loading')
      entry.key: entry.value,
});

/// A header button, then a batch of item buttons once [load] completes.
/// [spinner] keeps a progress indicator turning beside the content for ever;
/// [entrance] fades a box in over 300 ms right after the page appears.
class _LoadingPage extends StatelessWidget {
  const _LoadingPage({
    required this.load,
    this.spinner = false,
    this.entrance = false,
  });

  final Future<List<int>> load;
  final bool spinner;
  final bool entrance;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FutureBuilder<List<int>>(
      future: load,
      builder: (context, snapshot) => Column(
        children: [
          FilledButton(onPressed: () {}, child: const Text('Header')),
          if (entrance)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 300),
              builder: (_, value, _) => Opacity(
                opacity: value,
                child: const SizedBox(height: 10, width: 10),
              ),
            ),
          if (spinner)
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(),
            ),
          if (snapshot.hasData)
            for (final i in snapshot.data!)
              FilledButton(onPressed: () {}, child: Text('Item $i')),
        ],
      ),
    ),
  );
}

/// Toggles one button's height every [period] for ever: a looping animation
/// between two layouts.
class _Toggling extends StatefulWidget {
  const _Toggling({required this.period});

  final Duration period;

  @override
  State<_Toggling> createState() => _TogglingState();
}

class _TogglingState extends State<_Toggling> {
  Timer? _timer;
  bool _tall = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.period, (_) {
      setState(() => _tall = !_tall);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FilledButton(onPressed: () {}, child: const Text('Header')),
      SizedBox(
        height: _tall ? 90 : 40,
        width: 200,
        child: FilledButton(onPressed: () {}, child: const Text('Grow')),
      ),
    ],
  );
}

/// A paginated list that appends a row every [period] for ever.
class _Appending extends StatefulWidget {
  const _Appending({required this.period});

  final Duration period;

  @override
  State<_Appending> createState() => _AppendingState();
}

class _AppendingState extends State<_Appending> {
  Timer? _timer;
  int _rows = 1;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.period, (_) {
      if (_rows < 12) setState(() => _rows++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < _rows; i++)
        SizedBox(
          height: 40,
          child: FilledButton(onPressed: () {}, child: Text('Row $i')),
        ),
    ],
  );
}

/// A colour animates for ever and nothing moves.
class _Blinking extends StatefulWidget {
  const _Blinking();

  @override
  State<_Blinking> createState() => _BlinkingState();
}

class _BlinkingState extends State<_Blinking>
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
  Widget build(BuildContext context) => Column(
    children: [
      FilledButton(onPressed: () {}, child: const Text('Header')),
      AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => ColoredBox(
          color: Color.lerp(Colors.black, Colors.white, _controller.value)!,
          child: const SizedBox(height: 40, width: 40),
        ),
      ),
    ],
  );
}

/// One button whose height follows [height] and which sits beneath a
/// [TugboatLoading] marker while [loading] is true.
class _Resizable extends StatelessWidget {
  const _Resizable({required this.height, required this.loading});

  final ValueNotifier<double> height;
  final ValueNotifier<bool> loading;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        FilledButton(onPressed: () {}, child: const Text('Header')),
        ListenableBuilder(
          listenable: Listenable.merge([height, loading]),
          builder: (context, _) {
            final button = SizedBox(
              height: height.value,
              width: 200,
              child: FilledButton(onPressed: () {}, child: const Text('Body')),
            );
            return loading.value ? TugboatLoading(child: button) : button;
          },
        ),
      ],
    ),
  );
}

/// A page that pushes a second route from 'Go' and reveals a new button from
/// 'Reveal', over a scrollable list.
class _FlowPage extends StatefulWidget {
  const _FlowPage({required this.scroll});

  final ScrollController scroll;

  @override
  State<_FlowPage> createState() => _FlowPageState();
}

class _FlowPageState extends State<_FlowPage> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        FilledButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () {},
                    child: const Text('Second'),
                  ),
                ),
              ),
            ),
          ),
          child: const Text('Go'),
        ),
        FilledButton(
          onPressed: () => setState(() => _revealed = true),
          child: const Text('Reveal'),
        ),
        if (_revealed)
          FilledButton(onPressed: () {}, child: const Text('Revealed')),
        Expanded(
          child: ListView.builder(
            controller: widget.scroll,
            itemCount: 40,
            itemBuilder: (_, i) =>
                FilledButton(onPressed: () {}, child: Text('Row $i')),
          ),
        ),
      ],
    ),
  );
}

/// Scrolls, taps 'Reveal', then taps 'Go'. Returns the inventory counts after
/// the scroll and after the reveal.
Future<({int afterScroll, int afterReveal})> _runFlow(
  WidgetTester tester,
  TugboatReplayConfig config,
) async {
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  await _mount(tester, _FlowPage(scroll: scroll), config);
  await tester.drag(find.byType(ListView), const Offset(0, -300));
  await waitForTugboatCaptureWork(tester);
  await _advance(tester, const Duration(seconds: 1));
  final afterScroll = _inventories().length;
  await tester.tap(find.text('Reveal'));
  await waitForTugboatCaptureWork(tester);
  await _advance(tester, const Duration(seconds: 1));
  final afterReveal = _inventories().length;
  await tester.tap(find.text('Go'));
  await waitForTugboatCaptureWork(tester);
  await _advance(tester, const Duration(seconds: 1));
  return (afterScroll: afterScroll, afterReveal: afterReveal);
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  group('a page that loads after its first inventory', () {
    for (final delay in const [
      Duration(milliseconds: 100),
      Duration(seconds: 1),
      Duration(seconds: 8),
    ]) {
      testWidgets('emits one settled inventory when it loads after $delay', (
        tester,
      ) async {
        final load = Completer<List<int>>();
        await _mount(tester, _LoadingPage(load: load.future), _exploration);
        final first = _inventories().first;
        expect(first['trigger'], 'initial');
        expect(_elements(first), hasLength(1));

        await _advance(tester, delay);
        load.complete([1, 2, 3, 4]);
        await _advance(tester, const Duration(seconds: 2));

        final settled = _settled();
        expect(settled, hasLength(1));
        expect(_elements(settled.single), hasLength(5));
        expect(settled.single['routeKey'], first['routeKey']);
      });
    }

    testWidgets(
      'still emits when an entrance animation settled before the load',
      (tester) async {
        // The entrance animation gives the watch a sample that finds nothing
        // new before the content arrives; the watch must stay armed.
        final load = Completer<List<int>>();
        await _mount(
          tester,
          _LoadingPage(load: load.future, entrance: true),
          _exploration,
        );
        await _advance(tester, const Duration(milliseconds: 1500));
        expect(_controller.debugSettledSampleCount, greaterThan(0));
        expect(_settled(), isEmpty);

        load.complete([1, 2, 3]);
        await _advance(tester, const Duration(seconds: 2));

        expect(_settled(), hasLength(1));
        expect(_elements(_settled().single), hasLength(4));
      },
    );

    testWidgets(
      'emits once beside a spinner that never stops, and backs off after',
      (tester) async {
        final load = Completer<List<int>>();
        await _mount(
          tester,
          _LoadingPage(load: load.future, spinner: true),
          _exploration,
        );
        await _advance(tester, const Duration(seconds: 1));
        load.complete([1, 2, 3]);
        await _advance(tester, const Duration(seconds: 24));

        final settled = _settled();
        expect(settled, hasLength(1));
        expect(_elements(settled.single), hasLength(4));
        // Sampled while the spinner turned, ever more rarely: forced samples
        // every 2 s at first, then windows doubling up to 6.4 s.
        final samples = _controller.debugSettledSampleCount;
        expect(samples, inInclusiveRange(3, 10));
      },
    );
  });

  group('no duplicates', () {
    testWidgets('an unchanged page is not sampled again once settled', (
      tester,
    ) async {
      await _mount(
        tester,
        _LoadingPage(load: Future.value(const [1, 2, 3, 4])),
        _exploration,
      );
      await _advance(tester, const Duration(seconds: 2));
      final before = _inventories().length;
      final samples = _controller.debugSettledSampleCount;

      await _advance(tester, const Duration(seconds: 30));

      expect(_inventories(), hasLength(before));
      expect(_settled(), isEmpty);
      // Armed, but an idle page draws no frame: no sample, no timer.
      expect(_controller.debugSettledSampleCount, samples);
      expect(_controller.debugSettledWatchArmed, isTrue);
      expect(_controller.debugSettledWatchHasTimer, isFalse);
    });

    testWidgets('a looping colour animation is sampled but emits nothing', (
      tester,
    ) async {
      await _mount(tester, const _Blinking(), _exploration);
      final before = _inventories().length;

      await _advance(tester, const Duration(seconds: 20));

      expect(_inventories(), hasLength(before));
      expect(_settled(), isEmpty);
      final samples = _controller.debugSettledSampleCount;
      expect(samples, inInclusiveRange(2, 10));
    });

    testWidgets('a blinking text cursor is sampled but emits nothing', (
      tester,
    ) async {
      await _mount(
        tester,
        const Scaffold(body: TextField(autofocus: true)),
        _exploration,
      );
      await _advance(tester, const Duration(seconds: 1));
      final before = _inventories().length;
      final samples = _controller.debugSettledSampleCount;

      await _advance(tester, const Duration(seconds: 10));

      expect(_inventories(), hasLength(before));
      expect(_settled(), isEmpty);
      expect(_controller.debugSettledSampleCount, greaterThan(samples));
    });

    testWidgets('a layout looping between two states emits each state once', (
      tester,
    ) async {
      await _mount(
        tester,
        const _Toggling(period: Duration(milliseconds: 600)),
        _exploration,
      );

      await _advance(tester, const Duration(seconds: 10));

      // Short was the initial inventory; tall is new once, then both repeat.
      expect(_settled(), hasLength(1));
    });

    testWidgets('a page that keeps growing stops at five settled inventories', (
      tester,
    ) async {
      await _mount(
        tester,
        const _Appending(period: Duration(milliseconds: 600)),
        _exploration,
      );

      await _advance(tester, const Duration(seconds: 10));

      final settled = _settled();
      expect(settled, hasLength(5));
      expect(settled.map((inv) => _elements(inv).length).toList(), [
        2,
        3,
        4,
        5,
        6,
      ]);
      expect(_controller.debugSettledWatchArmed, isFalse);
    });

    testWidgets('a tap that changes nothing does not re-emit as settled', (
      tester,
    ) async {
      await _mount(
        tester,
        _LoadingPage(load: Future.value(const [1, 2])),
        _exploration,
      );
      await _advance(tester, const Duration(seconds: 2));
      final before = _inventories().length;

      await tester.tap(find.text('Item 1'));
      await waitForTugboatCaptureWork(tester);
      await _advance(tester, const Duration(seconds: 3));

      expect(_settled(), isEmpty);
      expect(
        _inventories().skip(before).map((inv) => inv['trigger']),
        everyElement(isNot('settled')),
      );
    });
  });

  group('structural signature', () {
    testWidgets('the same fingerprints with a new layout emit as settled', (
      tester,
    ) async {
      final height = ValueNotifier<double>(40);
      final loading = ValueNotifier<bool>(false);
      addTearDown(height.dispose);
      addTearDown(loading.dispose);
      await _mount(
        tester,
        _Resizable(height: height, loading: loading),
        _exploration,
      );
      final first = _inventories().last;

      height.value = 90;
      await _advance(tester, const Duration(seconds: 2));

      final settled = _settled();
      expect(settled, hasLength(1));
      expect(settled.single['inventoryHash'], first['inventoryHash']);
    });

    testWidgets('sub-pixel jitter is sampled but emits nothing', (
      tester,
    ) async {
      final height = ValueNotifier<double>(40);
      final loading = ValueNotifier<bool>(false);
      addTearDown(height.dispose);
      addTearDown(loading.dispose);
      await _mount(
        tester,
        _Resizable(height: height, loading: loading),
        _exploration,
      );

      for (final value in const [40.3, 40.0, 40.4]) {
        height.value = value;
        await _advance(tester, const Duration(seconds: 1));
      }

      expect(_controller.debugSettledSampleCount, greaterThan(0));
      expect(_settled(), isEmpty);
    });

    testWidgets('a skeleton replaced in place by its loaded control emits', (
      tester,
    ) async {
      final height = ValueNotifier<double>(40);
      final loading = ValueNotifier<bool>(true);
      addTearDown(height.dispose);
      addTearDown(loading.dispose);
      await _mount(
        tester,
        _Resizable(height: height, loading: loading),
        _exploration,
      );
      final first = _inventories().last;
      expect((first['loading']! as Map)['placeholders'], 1);

      loading.value = false;
      await _advance(tester, const Duration(seconds: 2));

      final settled = _settled();
      expect(settled, hasLength(1));
      // Same fingerprints and boxes: only the loading evidence moved.
      expect(settled.single['inventoryHash'], first['inventoryHash']);
      expect((settled.single['loading']! as Map)['placeholders'], 0);
    });
  });

  group('lifecycle', () {
    /// Mounts a page that is loading and draws one frame after its first
    /// inventory, so a quiet window is pending when the test acts.
    Future<Completer<List<int>>> mountWithPendingWindow(
      WidgetTester tester,
    ) async {
      final load = Completer<List<int>>();
      final later = Completer<List<int>>();
      await _mount(
        tester,
        FutureBuilder<List<int>>(
          future: load.future,
          builder: (context, snapshot) => _LoadingPage(load: later.future),
        ),
        _exploration,
      );
      load.complete(const []);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_controller.debugSettledWatchHasTimer, isTrue);
      return later;
    }

    testWidgets('a route push stops the watch of the route it covers', (
      tester,
    ) async {
      final later = await mountWithPendingWindow(tester);
      final routeKey = _inventories().first['routeKey'];
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));

      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: FilledButton(onPressed: () {}, child: const Text('Next')),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(_controller.debugSettledWatchHasTimer, isFalse);
      later.complete([1, 2, 3]);
      await _advance(tester, const Duration(seconds: 3));

      expect(_settled().where((inv) => inv['routeKey'] == routeKey), isEmpty);
    });

    testWidgets('pausing capture stops the watch', (tester) async {
      final later = await mountWithPendingWindow(tester);

      _controller.setCapturePaused(true);
      expect(_controller.debugSettledWatchArmed, isFalse);
      later.complete([1, 2, 3]);
      await _advance(tester, const Duration(seconds: 2));

      expect(_settled(), isEmpty);
    });

    testWidgets('a lifecycle pause stops it and a resume re-arms it', (
      tester,
    ) async {
      final later = await mountWithPendingWindow(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(_controller.debugSettledWatchArmed, isFalse);
      later.complete([1, 2, 3]);
      await _advance(tester, const Duration(seconds: 2));
      expect(_settled(), isEmpty);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await waitForTugboatCaptureWork(tester);
      expect(_controller.debugSettledWatchArmed, isTrue);
    });

    testWidgets('ending the session stops the watch', (tester) async {
      await mountWithPendingWindow(tester);

      unawaited(_controller.endSession());
      expect(_controller.debugSettledWatchArmed, isFalse);
      expect(_controller.debugSettledWatchHasTimer, isFalse);
      await waitForTugboatCaptureWork(tester);
    });

    testWidgets('unmounting mid-window leaves no timer behind', (tester) async {
      await mountWithPendingWindow(tester);

      // Disposes the controller. A leaked window timer fails this test.
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('production and the off switch', () {
    Future<void> loadAndTap(
      WidgetTester tester,
      TugboatReplayConfig config,
    ) async {
      final load = Completer<List<int>>();
      await _mount(tester, _LoadingPage(load: load.future), config);
      load.complete([1, 2, 3]);
      await _advance(tester, const Duration(seconds: 1));
      await tester.tap(find.text('Item 1'));
      await waitForTugboatCaptureWork(tester);
      await _advance(tester, const Duration(seconds: 2));
    }

    for (final (name, config) in [
      ('the production config', _production),
      ('a semantic-map-only config', _semanticMapOnly),
      ('exploration with the re-sample off', _resampleOff),
    ]) {
      testWidgets('$name never arms the watch or samples', (tester) async {
        await loadAndTap(tester, config);

        expect(_controller.debugSettledWatchArmed, isFalse);
        expect(_controller.debugSettledWatchHasTimer, isFalse);
        expect(_controller.debugSettledSampleCount, 0);
        expect(_settled(), isEmpty);
      });
    }

    testWidgets('production events carry no inventory or loading evidence', (
      tester,
    ) async {
      await loadAndTap(tester, _production);

      final events = _controller.session!.events;
      expect(events.where((e) => e.type == 'interaction'), isNotEmpty);
      final encoded = jsonEncode([for (final e in events) e.data]);
      expect(encoded, isNot(contains('scene_inventory')));
      expect(encoded, isNot(contains('"loading"')));
      expect(encoded, isNot(contains('"placeholder"')));
      expect(encoded, isNot(contains('"settled"')));
    });

    testWidgets(
      'with the re-sample off the page stays at its first inventory',
      (tester) async {
        final load = Completer<List<int>>();
        await _mount(tester, _LoadingPage(load: load.future), _resampleOff);
        load.complete([1, 2, 3, 4]);
        await _advance(tester, const Duration(seconds: 2));

        expect(_inventories(), hasLength(1));
      },
    );
  });

  group('trigger', () {
    testWidgets('a scroll is never reported as a tap', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await _mount(tester, _FlowPage(scroll: scroll), _resampleOff);
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await waitForTugboatCaptureWork(tester);
      await _advance(tester, const Duration(seconds: 1));

      final triggers = [for (final inv in _inventories()) inv['trigger']];
      expect(triggers.first, 'initial');
      expect(triggers.skip(1), isNotEmpty);
      expect(triggers.skip(1), everyElement('scroll'));
    });

    testWidgets('initial, scroll, tap and route each carry their own trigger', (
      tester,
    ) async {
      final marks = await _runFlow(tester, _resampleOff);

      List<Object?> triggersBetween(int from, int to) => [
        for (final inv in _inventories().sublist(from, to)) inv['trigger'],
      ];
      final all = _inventories().length;
      expect(triggersBetween(0, 1), ['initial']);
      expect(triggersBetween(1, marks.afterScroll), everyElement('scroll'));
      final tap = triggersBetween(marks.afterScroll, marks.afterReveal);
      expect(tap, isNotEmpty);
      expect(tap, everyElement('tap'));
      expect(triggersBetween(marks.afterReveal, all), contains('route'));
      expect(
        triggersBetween(marks.afterReveal, all),
        isNot(contains('scroll')),
      );
    });

    testWidgets(
      'with the re-sample on, the only extra inventories are settled ones',
      (tester) async {
        await _runFlow(tester, _resampleOff);
        final off = [
          for (final inv in _inventories()) [inv['trigger'], _structure(inv)],
        ];
        await tester.pumpWidget(const SizedBox());
        TugboatReplay.resetForTest();

        await _runFlow(tester, _exploration);
        final on = [
          for (final inv in _inventories())
            if (inv['trigger'] != 'settled') [inv['trigger'], _structure(inv)],
        ];

        expect(on, off);
      },
    );

    testWidgets(
      'with the re-sample off, a tap, scroll and route flow emits exactly the inventories it always did',
      (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await _mount(
          tester,
          Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          body: Center(
                            child: FilledButton(
                              onPressed: () {},
                              child: const Text('Second'),
                            ),
                          ),
                        ),
                      ),
                    ),
                    child: const Text('Go'),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: scroll,
                      itemCount: 40,
                      itemBuilder: (_, i) =>
                          FilledButton(onPressed: () {}, child: Text('Row $i')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _resampleOff,
        );
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await waitForTugboatCaptureWork(tester);
        await tester.tap(find.text('Go'));
        await waitForTugboatCaptureWork(tester);
        await _advance(tester, const Duration(seconds: 1));

        // (routeKey, inventoryHash, element count) measured on fdd0aa2, before
        // the settled re-sample existed.
        expect(
          [
            for (final inv in _inventories())
              [inv['routeKey'], inv['inventoryHash'], _elements(inv).length],
          ],
          [
            ['/', '8e0fe11f97c5d88b', 14],
            ['/', '7b44e9db023584a7', 3],
            ['/', '0d92151895d2f459', 15],
            ['/', '0d92151895d2f459', 15],
            ['struct:de6eee2c7e62f2ef', '141a48eb7189ba17', 1],
          ],
        );
      },
    );
  });
}
