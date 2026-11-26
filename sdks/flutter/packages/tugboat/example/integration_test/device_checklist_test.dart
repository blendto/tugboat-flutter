import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tugboat/tugboat.dart';

/// Device feature checklist: one independent row per SDK capture feature.
///
/// Each row mounts its own fixture app, records pass or fail with a one-line
/// reason, and never fails the test process, so one broken feature cannot
/// hide the rest. Results go to `binding.reportData` (written on the host by
/// `flutter drive`, see test_driver/integration_test.dart) and to one
/// `TBCHECK {...}` log line per row.
///
/// Run with `tool/ci/device-report/run-device-suite.sh`, or by hand:
///
/// ```sh
/// TBPROF_OUT=device_checklist flutter drive -d DEVICE \
///   --driver test_driver/integration_test.dart \
///   --target integration_test/device_checklist_test.dart
/// ```
const _home = '/';
const _details = '/details';
const _feed = '/feed';
const _button = 'checklist-button';
const _switch = 'checklist-switch';
const _open = 'checklist-details';
const _openFeed = 'checklist-feed';
const _privateTile = ValueKey('private-tile');
const _publicTile = ValueKey('public-tile');

final _rows = <Map<String, Object?>>[];

typedef _Body = Future<void> Function(WidgetTester tester);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.reportData = <String, Object?>{
    'checklist': _rows,
    'mode': kProfileMode
        ? 'profile'
        : kReleaseMode
        ? 'release'
        : 'debug',
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
  };

  _check('session', 'Session start/end with a single session id', _session);
  _check('routes', 'Named routes: session start, push, pop', _routes);
  _check('inventory', 'Scene inventory with bounds for tagged controls', (
    tester,
  ) async {
    final app = await _Fixture.start(tester);
    for (final tag in [_button, _switch, _open]) {
      final entry = app.control(tag);
      _require(
        (entry['fingerprint'] as String?)?.isNotEmpty ?? false,
        '$tag has no fingerprint',
      );
      final bounds = entry['boundsNorm'] as Map<String, Object?>?;
      _require(
        bounds != null &&
            (bounds['width']! as num) > 0 &&
            (bounds['height']! as num) > 0,
        '$tag has empty boundsNorm $bounds',
      );
    }
  });
  _check('tap_repeat', 'Repeat taps keep one fingerprint', (tester) async {
    final app = await _Fixture.start(tester);
    final first = await app.tap(_button);
    final second = await app.tap(_button);
    _require(first == second, 'fingerprints differ: $first vs $second');
    _require(find.text('Count: 2').evaluate().isNotEmpty, 'counter not at 2');
  });
  _check('tap_distinct', 'Distinct fingerprints across controls', (
    tester,
  ) async {
    final app = await _Fixture.start(tester);
    final prints = {
      for (final tag in [_button, _switch]) tag: await app.tap(tag),
    };
    _require(
      prints.values.toSet().length == prints.length,
      'controls share a fingerprint: $prints',
    );
  });
  _check('tap_inventory', 'Tap fingerprint matches its inventory entry', (
    tester,
  ) async {
    final app = await _Fixture.start(tester);
    for (final tag in [_button, _switch]) {
      final fingerprint = await app.tap(tag);
      final entry = app.control(tag);
      final known = [
        entry['fingerprint'],
        ...(entry['aliases'] as List? ?? const []),
      ];
      _require(
        known.contains(fingerprint),
        '$tag tap $fingerprint not in inventory $known',
      );
    }
  });
  _check('scroll', 'Scroll interaction, frame and inventory', _scroll);
  _check(
    'masking',
    'Masked frame: sensitive tile hidden, neighbour visible',
    (tester) => _masking(
      tester,
      TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
    ),
  );
  _check('lifecycle', 'App pause/resume emits a lifecycle frame', _lifecycle);
  _check(
    'native_cpu',
    'Native CPU backend captures and masks',
    (tester) =>
        _masking(tester, TugboatScreenshotCaptureBackend.nativeCpuExperimental),
  );
  _check(
    'sink_throws',
    'Throwing sink does not break the host app',
    _throwingSink,
  );
  _check(
    'sink_futures',
    'SDK handles the futures a sink returns',
    _sinkFutures,
  );
  _check('disabled', 'Disabled config returns the child unchanged', _disabled);
}

/// Registers one row as its own test. Failures are recorded, not rethrown.
///
/// No row may provoke an error the SDK leaves unhandled: in the live test
/// binding an uncaught async error aborts the running test and the report.
/// [_sinkFutures] checks for that without throwing.
void _check(String id, String title, _Body body) {
  testWidgets(title, (tester) async {
    final clock = Stopwatch()..start();
    String? failure;
    try {
      await body(tester);
      failure = _leaked(tester);
    } catch (error) {
      failure = _leaked(tester) ?? _oneLine(error);
    }
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpFor(tester, const Duration(milliseconds: 500));
      failure ??= _leaked(tester);
    } catch (error) {
      failure ??= 'teardown: ${_oneLine(error)}';
    }
    TugboatReplay.resetForTest();
    final row = <String, Object?>{
      'id': id,
      'title': title,
      'pass': failure == null,
      if (failure != null) 'reason': failure,
      'ms': clock.elapsedMilliseconds,
    };
    _rows.add(row);
    debugPrint('TBCHECK ${jsonEncode(row)}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// A Flutter error report the host app would have seen.
String? _leaked(WidgetTester tester) {
  final error = tester.takeException();
  if (error == null) return null;
  return 'host app saw ${error.runtimeType}: ${_oneLine(error)}';
}

class _CheckFailure implements Exception {
  const _CheckFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

void _require(bool condition, String message) {
  if (!condition) throw _CheckFailure(message);
}

String _oneLine(Object error) {
  final text = error is TestFailure ? (error.message ?? '$error') : '$error';
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > 240 ? '${flat.substring(0, 237)}...' : flat;
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < duration) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _session(WidgetTester tester) async {
  final app = await _Fixture.start(tester);
  final sink = app.sink;
  _require(sink.sessions.length == 1, '${sink.sessions.length} sessions');
  final id = sink.sessions.single.captureSessionId;
  _require(id.isNotEmpty, 'empty captureSessionId');
  _require(
    sink.events.first.type == 'session_start',
    'first event is ${sink.events.first.type}',
  );
  await tester.pumpWidget(const SizedBox.shrink());
  await app.waitFor(
    'session end',
    () => sink.finished && sink.events.any((e) => e.type == 'session_end'),
  );
  final ids = sink.envelopes.map((e) => e.captureSessionId).toSet();
  _require(ids.length == 1 && ids.single == id, 'session ids $ids');
}

Future<void> _routes(WidgetTester tester) async {
  final app = await _Fixture.start(tester);
  await app.tap(_open);
  await app.waitFor(
    'route_push to $_details',
    () => app.sink.hasRoute(_details, 'route_push', from: _home),
  );
  await tester.tap(find.text('Close details'));
  await app.waitFor(
    'route_pop back to $_home',
    () => app.sink.hasRoute(_home, 'route_pop', from: _details),
  );
}

Future<void> _scroll(WidgetTester tester) async {
  final app = await _Fixture.start(tester);
  await app.tap(_openFeed);
  await app.waitFor(
    'feed inventory',
    () => app.sink.inventories(_feed).isNotEmpty,
  );
  final framesBefore = app.sink.frames.length;
  await tester.drag(find.byType(ListView), const Offset(0, -600));
  await app.waitFor(
    'scroll interaction with a frame',
    () => app.sink.scrolls.any((e) => e.afterFrame != null),
  );
  final scroll = app.sink.scrolls.firstWhere((e) => e.afterFrame != null);
  final payload = scroll.data['payload'] as Map<String, Object?>?;
  final endOffset = payload?['endOffset'] as num?;
  _require(endOffset != null && endOffset > 0, 'scroll endOffset $endOffset');
  _require(
    app.sink.frames.length > framesBefore,
    'no frame captured after the scroll',
  );
  await app.waitFor(
    'scene_inventory with trigger scroll',
    () => app.sink.inventories(_feed).any((e) => e.data['trigger'] == 'scroll'),
  );
}

Future<void> _masking(
  WidgetTester tester,
  TugboatScreenshotCaptureBackend backend,
) async {
  final app = await _Fixture.start(tester, backend: backend);
  final envelope = app.sink.frames.first;
  final frame = envelope.frame!;
  _require(
    frame.resolvedBackend == backend,
    'resolved ${frame.resolvedBackend?.name} '
    '(fallbackReason ${frame.fallbackReason})',
  );
  _require(frame.masked, 'frame not marked masked');
  final bytes = envelope.frameBytes!;
  _require(
    bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0xd8,
    'frame is not a JPEG',
  );
  final boundary = tester.getRect(find.byKey(TugboatReplay.boundaryKey));
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  try {
    final rgba = (await image.toByteData())!;
    List<int> rgbAt(Offset point) {
      final x = ((point.dx - boundary.left) * image.width / boundary.width)
          .floor();
      final y = ((point.dy - boundary.top) * image.height / boundary.height)
          .floor();
      final offset = 4 * (y * image.width + x);
      return [for (var c = 0; c < 3; c++) rgba.getUint8(offset + c)];
    }

    final private = rgbAt(tester.getCenter(find.byKey(_privateTile)));
    final public = rgbAt(tester.getCenter(find.byKey(_publicTile)));
    // The private tile is magenta and must be filled; the public tile is
    // green and must stay green. JPEG shifts solid colors slightly.
    final magenta = private[0] > 200 && private[1] < 60 && private[2] > 200;
    _require(!magenta, 'sensitive tile visible: rgb $private');
    final green = public[0] < 40 && public[1] > 210 && public[2] < 40;
    _require(green, 'neighbour tile not visible: rgb $public');
  } finally {
    image.dispose();
    codec.dispose();
  }
}

Future<void> _lifecycle(WidgetTester tester) async {
  final app = await _Fixture.start(tester);
  final binding = tester.binding;
  binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  try {
    // Paused disables frames, so wait on the clock instead of pumping.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  } finally {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
  await app.waitFor(
    'lifecycle frame after resume',
    () => app.sink.frames.any(
      (e) => e.frame!.trigger == TugboatFrameTrigger.lifecycle,
    ),
  );
  final types = app.sink.events.map((e) => e.type).toList();
  _require(
    types.contains('app_backgrounded') && types.contains('app_foregrounded'),
    'missing app_backgrounded/app_foregrounded',
  );
  _require(!types.contains('session_end'), 'pause ended the session');
}

Future<void> _throwingSink(WidgetTester tester) async {
  final app = await _Fixture.start(tester, extraSinks: [_ThrowingSink()]);
  await app.tap(_button);
  _require(find.text('Count: 1').evaluate().isNotEmpty, 'counter not at 1');
  _require(app.sink.frames.isNotEmpty, 'healthy sink got no frames');
}

Future<void> _sinkFutures(WidgetTester tester) async {
  final probe = _ProbeSink();
  final app = await _Fixture.start(tester, extraSinks: [probe]);
  await app.tap(_button);
  await tester.pumpWidget(const SizedBox.shrink());
  await app.waitFor(
    'probe sink disposed',
    () => probe.calls.contains('dispose'),
  );
  final dropped = [
    for (final MapEntry(key: name, value: future) in probe.futures.entries)
      if (!future.observed) '$name()',
  ];
  _require(
    dropped.isEmpty,
    'SDK drops the future from ${dropped.join(', ')}: a sink whose '
    '${dropped.length == 1 ? 'call fails' : 'calls fail'} there would raise '
    'an uncaught async error in the host app',
  );
}

Future<void> _disabled(WidgetTester tester) async {
  final sink = _RecordingSink();
  await tester.pumpWidget(_fixtureApp(sink, enabled: false));
  await _pumpFor(tester, const Duration(seconds: 2));
  _require(TugboatReplay.controller == null, 'controller was created');
  _require(
    find.byKey(TugboatReplay.boundaryKey).evaluate().isEmpty,
    'capture boundary was mounted',
  );
  _require(sink.sessions.isEmpty, 'a capture session started');
  await tester.tap(find.widgetWithText(FilledButton, 'Count'));
  await tester.pump();
  _require(find.text('Count: 1').evaluate().isNotEmpty, 'counter not at 1');
  _require(sink.envelopes.isEmpty, 'disabled SDK delivered envelopes');
}

/// One mounted fixture app with its recording sink.
class _Fixture {
  _Fixture(this.tester, this.sink);

  final WidgetTester tester;
  final _RecordingSink sink;
  late final Map<String, Map<String, Object?>> _controls;

  static Future<_Fixture> start(
    WidgetTester tester, {
    TugboatScreenshotCaptureBackend backend =
        TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
    List<TugboatCaptureSinkFactory> extraSinks = const [],
    bool waitForCapture = true,
  }) async {
    final sink = _RecordingSink();
    final fixture = _Fixture(tester, sink);
    await tester.pumpWidget(
      _fixtureApp(sink, backend: backend, extraSinks: extraSinks),
    );
    if (!waitForCapture) return fixture;
    await fixture.waitFor(
      'initial frame and home inventory',
      () =>
          sink.frames.isNotEmpty &&
          sink.hasRoute(_home, tugboatNavigationSessionStart) &&
          sink.inventories(_home).isNotEmpty,
    );
    fixture._controls = {
      for (final entry
          in (sink.inventories(_home).first.data['elements'] as List)
              .cast<Map<String, Object?>>())
        if (entry['tier'] == 'interactive' && entry['tag'] is String)
          entry['tag']! as String: entry,
    };
    return fixture;
  }

  Map<String, Object?> control(String tag) {
    final entry = _controls[tag];
    _require(entry != null, '$tag missing from home inventory');
    return entry!;
  }

  /// Taps the tagged control and returns the tap's target fingerprint.
  Future<String> tap(String tag) async {
    final before = sink.taps.length;
    await tester.tap(find.byKey(ValueKey(tag)));
    await waitFor('tap on $tag', () => sink.taps.length > before);
    final fingerprint = sink.taps[before].data['targetFingerprint'];
    _require(fingerprint is String, 'tap on $tag has no targetFingerprint');
    return fingerprint! as String;
  }

  Future<void> waitFor(String what, bool Function() condition) async {
    final clock = Stopwatch()..start();
    while (!condition() && clock.elapsed < const Duration(seconds: 12)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    _require(
      condition(),
      'timed out waiting for $what (${sink.frames.length} frames, '
      '${sink.events.length} events)',
    );
  }
}

Widget _fixtureApp(
  _RecordingSink sink, {
  bool enabled = true,
  TugboatScreenshotCaptureBackend backend =
      TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
  List<TugboatCaptureSinkFactory> extraSinks = const [],
}) {
  return MaterialApp(
    navigatorObservers: [TugboatReplay.navigatorObserver],
    builder: (_, child) => TugboatReplay.wrapApp(
      config: TugboatReplayConfig(
        enabled: enabled,
        emitSceneInventory: true,
        capturePixelRatio: 0.75,
        screenshotCaptureBackend: backend,
        sinkFactories: [...extraSinks, sink],
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
      _feed: (context) => Scaffold(
        appBar: AppBar(title: const Text('Feed')),
        body: ListView.builder(
          itemCount: 60,
          itemBuilder: (context, index) => TugboatTag(
            'feed-item-$index',
            child: ListTile(title: Text('Feed item $index'), onTap: () {}),
          ),
        ),
      ),
    },
  );
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  int _count = 0;
  bool _enabled = false;

  Widget _tagged(String tag, Widget child) => TugboatTag(
    tag,
    child: KeyedSubtree(key: ValueKey(tag), child: child),
  );

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
              _tagged(
                _button,
                FilledButton(
                  onPressed: () => setState(() => _count++),
                  child: const Text('Count'),
                ),
              ),
              _tagged(
                _switch,
                Switch(
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
              ),
              _tagged(
                _open,
                FilledButton(
                  onPressed: () => Navigator.of(context).pushNamed(_details),
                  child: const Text('Open details'),
                ),
              ),
              _tagged(
                _openFeed,
                FilledButton(
                  onPressed: () => Navigator.of(context).pushNamed(_feed),
                  child: const Text('Open feed'),
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

  List<TugboatCaptureEnvelope> get frames => envelopes
      .where((entry) => entry.kind == TugboatEnvelopeKind.frame)
      .toList();

  List<TugboatEvent> get taps => _interactions('tap');

  List<TugboatEvent> get scrolls => _interactions('scroll');

  List<TugboatEvent> _interactions(String gesture) => events
      .where((e) => e.type == 'interaction' && e.data['gesture'] == gesture)
      .toList();

  Iterable<TugboatEvent> inventories(String route) => events.where(
    (e) => e.type == 'scene_inventory' && e.data['routeKey'] == route,
  );

  bool hasRoute(String route, String navigation, {String? from}) => events.any(
    (e) =>
        e.type == 'route_change' &&
        e.data['route'] == route &&
        e.data['navigation'] == navigation &&
        (from == null || e.data['fromRoute'] == from),
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

/// Throws from every sink callback: synchronously, and as failed futures
/// from flush() and finish(), which the SDK awaits.
class _ThrowingSink extends TugboatSessionCaptureSink
    implements TugboatCaptureSinkFactory {
  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) => this;

  @override
  void accept(TugboatCaptureEnvelope envelope) =>
      throw StateError('checklist sink accept');

  @override
  Future<void> start(TugboatSinkSessionContext context) =>
      throw StateError('checklist sink start');

  @override
  Future<void> flush() => Future.error(StateError('checklist sink flush'));

  @override
  Future<void> finish() => Future.error(StateError('checklist sink finish'));

  @override
  Future<void> dispose() => throw StateError('checklist sink dispose');
}

/// Returns futures that succeed and record whether the SDK subscribed to
/// them. An unobserved future that failed would be an uncaught async error.
class _ProbeSink extends TugboatSessionCaptureSink
    implements TugboatCaptureSinkFactory {
  final calls = <String>[];
  final futures = <String, _ProbeFuture>{};

  Future<void> _record(String name) {
    calls.add(name);
    return futures.putIfAbsent(name, _ProbeFuture.new);
  }

  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) => this;

  @override
  void accept(TugboatCaptureEnvelope envelope) {}

  @override
  Future<void> start(TugboatSinkSessionContext context) => _record('start');

  @override
  Future<void> flush() => _record('flush');

  @override
  Future<void> finish() => _record('finish');

  @override
  Future<void> dispose() => _record('dispose');
}

class _ProbeFuture implements Future<void> {
  final Future<void> _inner = Future<void>.value();
  bool observed = false;

  @override
  Future<R> then<R>(
    FutureOr<R> Function(void value) onValue, {
    Function? onError,
  }) {
    observed = true;
    return _inner.then(onValue, onError: onError);
  }

  @override
  Future<void> catchError(Function onError, {bool Function(Object)? test}) {
    observed = true;
    return _inner.catchError(onError, test: test);
  }

  @override
  Future<void> whenComplete(FutureOr<void> Function() action) {
    observed = true;
    return _inner.whenComplete(action);
  }

  @override
  Stream<void> asStream() {
    observed = true;
    return _inner.asStream();
  }

  @override
  Future<void> timeout(
    Duration timeLimit, {
    FutureOr<void> Function()? onTimeout,
  }) {
    observed = true;
    return _inner.timeout(timeLimit, onTimeout: onTimeout);
  }
}
