import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tugboat/tugboat.dart';

const _home = '/';
const _details = '/details';
const _button = 'smoke-button';
const _switch = 'smoke-switch';
const _open = 'smoke-details';
const _privateTile = ValueKey('private-tile');
const _publicTile = ValueKey('public-tile');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('captures routes, controls, fingerprints and masked frames', (
    tester,
  ) async {
    final sink = _RecordingSink();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (_, child) => TugboatReplay.wrapApp(
          config: TugboatReplayConfig(
            enabled: true,
            emitSceneInventory: true,
            capturePixelRatio: 0.75,
            sinkFactories: [sink],
          ),
          child: child!,
        ),
        home: const _HomePage(),
        routes: {
          _details: (context) => Scaffold(
            backgroundColor: Colors.blue,
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close details'),
              ),
            ),
          ),
        },
      ),
    );

    await _pumpUntil(
      tester,
      sink,
      'initial frame, route and inventory',
      () =>
          sink.frames.isNotEmpty &&
          sink.events.any(
            (event) =>
                event.type == 'route_change' &&
                event.data['route'] == _home &&
                event.data['navigation'] == tugboatNavigationSessionStart,
          ) &&
          sink.inventories(_home).isNotEmpty,
    );

    final session = sink.sessions.single;
    expect(session.captureSessionId, isNotEmpty);
    expect(sink.events.first.type, 'session_start');
    final homeInventory = sink.inventories(_home).first;
    expect(homeInventory.data['inventoryHash'], isNotEmpty);
    final controls = {
      for (final entry
          in (homeInventory.data['elements'] as List)
              .cast<Map<String, Object?>>())
        if (entry['tier'] == 'interactive') entry['tag']: entry,
    };
    for (final tag in [_button, _switch, _open]) {
      expect(controls, contains(tag));
      final entry = controls[tag]!;
      expect(entry['fingerprint'], isNotEmpty);
      final bounds = entry['boundsNorm'] as Map<String, Object?>;
      expect(bounds['width'], greaterThan(0));
      expect(bounds['height'], greaterThan(0));
    }

    final firstFrame = sink.frames.first;
    final frame = firstFrame.frame!;
    expect(frame.trigger, TugboatFrameTrigger.initial);
    expect(frame.masked, isTrue);
    expect(
      frame.resolvedBackend,
      TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
    );
    expect(frame.contentHash, isNotEmpty);
    final bytes = firstFrame.frameBytes!;
    expect(bytes, hasLength(frame.byteLength));
    expect(bytes.take(2), orderedEquals([0xff, 0xd8]));
    final boundary = tester.getRect(find.byKey(TugboatReplay.boundaryKey));
    final privateCenter = tester.getCenter(find.byKey(_privateTile));
    final publicCenter = tester.getCenter(find.byKey(_publicTile));
    final codec = await ui.instantiateImageCodec(bytes);
    final image = (await codec.getNextFrame()).image;
    try {
      expect(image.width, frame.width);
      expect(image.height, frame.height);
      final rgba = (await image.toByteData())!;
      List<int> rgbAt(Offset point) {
        final x = ((point.dx - boundary.left) * image.width / boundary.width)
            .floor();
        final y = ((point.dy - boundary.top) * image.height / boundary.height)
            .floor();
        final offset = 4 * (y * image.width + x);
        return [
          for (var channel = 0; channel < 3; channel++)
            rgba.getUint8(offset + channel),
        ];
      }

      // JPEG can shift pixel values slightly, even in a solid color tile.
      expect(rgbAt(privateCenter), everyElement(closeTo(26, 10)));
      expect(
        rgbAt(publicCenter),
        orderedEquals([lessThan(25), greaterThan(230), lessThan(25)]),
      );
    } finally {
      image.dispose();
      codec.dispose();
    }

    Future<String> tapTarget(Finder target, String tag) async {
      final before = sink.taps.length;
      await tester.tap(target);
      await _pumpUntil(
        tester,
        sink,
        'tap on $tag',
        () => sink.taps.length > before,
      );
      final tap = sink.taps[before];
      expect(tap.data['route'], _home);
      expect(tap.data['routeKey'], homeInventory.data['routeKey']);
      final fingerprint = tap.data['targetFingerprint'] as String;
      final entry = controls[tag]!;
      expect(
        [entry['fingerprint'], ...(entry['aliases'] as List? ?? const [])],
        contains(fingerprint),
        reason:
            'Tap fingerprint should identify the $tag entry in the inventory.',
      );
      return fingerprint;
    }

    final button = find.widgetWithText(FilledButton, 'Count');
    final buttonFingerprint = await tapTarget(button, _button);
    expect(find.text('Count: 1'), findsOneWidget);
    expect(await tapTarget(button, _button), buttonFingerprint);
    expect(find.text('Count: 2'), findsOneWidget);

    final toggle = find.byType(Switch);
    final switchFingerprint = await tapTarget(toggle, _switch);
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(switchFingerprint, isNot(buttonFingerprint));

    await tapTarget(find.widgetWithText(FilledButton, 'Open details'), _open);
    await _pumpUntil(
      tester,
      sink,
      'details route and inventory',
      () =>
          sink.events.any(
            (event) =>
                event.type == 'route_change' &&
                event.data['route'] == _details &&
                event.data['fromRoute'] == _home &&
                event.data['navigation'] == 'route_push',
          ) &&
          sink.inventories(_details).isNotEmpty,
    );
    expect(find.text('Close details'), findsOneWidget);
    expect(
      sink.inventories(_details).first.data['inventoryHash'],
      isNot(homeInventory.data['inventoryHash']),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(
      tester,
      sink,
      'session end',
      () =>
          sink.finished &&
          sink.events.any((event) => event.type == 'session_end'),
    );
    expect(sink.envelopes.map((entry) => entry.captureSessionId).toSet(), {
      session.captureSessionId,
    });
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  _RecordingSink sink,
  String description,
  bool Function() condition,
) async {
  final clock = Stopwatch()..start();
  while (!condition() && clock.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    condition(),
    isTrue,
    reason:
        'Timed out waiting for $description. Captured '
        '${sink.frames.length} frames and events '
        '${sink.events.map(_describe).join(', ')}.',
  );
}

String _describe(TugboatEvent event) {
  final fields = [
    for (final key in const ['route', 'fromRoute', 'navigation', 'routeKey'])
      if (event.data[key] case final Object value) '$key=$value',
  ];
  return fields.isEmpty ? event.type : '${event.type}(${fields.join(' ')})';
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  int _count = 0;
  bool _enabled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TugboatSensitive(
                    child: SizedBox(
                      key: _privateTile,
                      width: 64,
                      height: 64,
                      child: ColoredBox(color: Color(0xffff00ff)),
                    ),
                  ),
                  SizedBox(width: 16),
                  SizedBox(
                    key: _publicTile,
                    width: 64,
                    height: 64,
                    child: ColoredBox(color: Color(0xff00ff00)),
                  ),
                ],
              ),
              Text('Count: $_count'),
              TugboatTag(
                _button,
                child: FilledButton(
                  onPressed: () => setState(() => _count++),
                  child: const Text('Count'),
                ),
              ),
              TugboatTag(
                _switch,
                child: Switch(
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
              ),
              TugboatTag(
                _open,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pushNamed(_details),
                  child: const Text('Open details'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordingSink extends TugboatSessionCaptureSink
    implements TugboatCaptureSinkFactory {
  final envelopes = <TugboatCaptureEnvelope>[];
  final sessions = <TugboatSinkSessionContext>[];
  bool finished = false;

  Iterable<TugboatEvent> get events =>
      envelopes.map((entry) => entry.event).whereType<TugboatEvent>();

  Iterable<TugboatCaptureEnvelope> get frames =>
      envelopes.where((entry) => entry.kind == TugboatEnvelopeKind.frame);

  List<TugboatEvent> get taps => events
      .where(
        (event) =>
            event.type == 'interaction' && event.data['gesture'] == 'tap',
      )
      .toList();

  Iterable<TugboatEvent> inventories(String route) => events.where(
    (event) =>
        event.type == 'scene_inventory' && event.data['routeKey'] == route,
  );

  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) => this;

  @override
  void accept(TugboatCaptureEnvelope envelope) => envelopes.add(envelope);

  @override
  Future<void> start(TugboatSinkSessionContext context) async {
    sessions.add(context);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> finish() async {
    finished = true;
  }

  @override
  Future<void> dispose() async {}
}
