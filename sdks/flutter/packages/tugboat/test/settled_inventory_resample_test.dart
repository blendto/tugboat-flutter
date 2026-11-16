import 'dart:async';

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
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

List<Map<String, Object?>> _settled() =>
    _inventories().where((inv) => inv['trigger'] == 'settled').toList();

List<Map<String, Object?>> _elements(Map<String, Object?> inventory) => [
  for (final e in inventory['elements']! as List) (e as Map).cast(),
];

/// A header button, then a batch of item buttons once [load] completes.
class _LoadingPage extends StatelessWidget {
  const _LoadingPage({required this.load});

  final Future<List<int>> load;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FutureBuilder<List<int>>(
      future: load,
      builder: (context, snapshot) => Column(
        children: [
          FilledButton(onPressed: () {}, child: const Text('Header')),
          if (snapshot.hasData)
            for (final i in snapshot.data!)
              FilledButton(onPressed: () {}, child: Text('Item $i')),
        ],
      ),
    ),
  );
}

/// Changes one button's height every [period]: a real structural change each
/// time, with no gesture.
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

/// A colour animates forever and nothing moves: a blinking cursor.
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

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets(
    'a FutureBuilder that loads later emits a settled inventory with no gesture',
    (tester) async {
      final load = Completer<List<int>>();
      await _mount(tester, _LoadingPage(load: load.future), _exploration);
      final first = _inventories().first;
      expect(first['trigger'], 'initial');
      // The initial inventory is taken while the page still shows the header.
      expect(_elements(first), hasLength(1));

      load.complete([1, 2, 3, 4]);
      await _advance(tester, const Duration(seconds: 2));

      final settled = _settled();
      expect(settled, hasLength(1));
      expect(_elements(settled.single), hasLength(5));
      expect(settled.single['routeKey'], first['routeKey']);
    },
  );

  testWidgets(
    'with resampleSettledInventory false the same page emits no settled inventory',
    (tester) async {
      final load = Completer<List<int>>();
      await _mount(tester, _LoadingPage(load: load.future), _resampleOff);
      load.complete([1, 2, 3, 4]);
      await _advance(tester, const Duration(seconds: 2));

      expect(_settled(), isEmpty);
      expect(_inventories(), hasLength(1));
    },
  );

  testWidgets('a production config never emits inventories', (tester) async {
    final load = Completer<List<int>>();
    await _mount(tester, _LoadingPage(load: load.future), _production);
    load.complete([1, 2, 3, 4]);
    await _advance(tester, const Duration(seconds: 2));

    expect([
      for (final event in TugboatReplay.controller!.session!.events)
        if (event.type == 'scene_inventory') event,
    ], isEmpty);
  });

  testWidgets('an unchanged page emits nothing extra over several seconds', (
    tester,
  ) async {
    await _mount(
      tester,
      _LoadingPage(load: Future.value(const [1, 2, 3, 4])),
      _exploration,
    );
    final before = _inventories().length;

    await _advance(tester, const Duration(seconds: 6));

    expect(_inventories(), hasLength(before));
    expect(_settled(), isEmpty);
  });

  testWidgets('a blinking cursor produces zero extra events', (tester) async {
    await _mount(tester, const _Blinking(), _exploration);
    final before = _inventories().length;

    await _advance(tester, const Duration(seconds: 6));

    expect(_inventories(), hasLength(before));
    expect(_settled(), isEmpty);
  });

  testWidgets(
    'a page that keeps changing emits at most five settled inventories',
    (tester) async {
      await _mount(
        tester,
        const _Toggling(period: Duration(milliseconds: 600)),
        _exploration,
      );

      await _advance(tester, const Duration(seconds: 10));

      // The per-route cap in lib/src/settled_inventory_watch.dart.
      expect(_settled(), hasLength(5));
    },
  );

  testWidgets('initial, tap, scroll and route captures carry their triggers', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _mount(
      tester,
      Builder(
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
      _resampleOff,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await waitForTugboatCaptureWork(tester);
    await tester.tap(find.text('Go'));
    await _advance(tester, const Duration(seconds: 1));

    final triggers = {for (final inv in _inventories()) inv['trigger']};
    expect(
      triggers,
      containsAll(<String>['initial', 'scroll', 'tap', 'route']),
    );
  });

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

      // (routeKey, inventoryHash, element count) measured on fdd0aa2, before the
      // settled re-sample existed. The same sequence is produced with the
      // re-sample on, because the flow never changes layout after an emission.
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
}
