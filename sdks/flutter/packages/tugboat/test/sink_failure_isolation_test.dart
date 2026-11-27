import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

// A sink failure must never reach the host app. An uncaught async error
// fails a widget test, so each test here fails if the SDK lets one escape.

const _config = TugboatReplayConfig(
  enabled: true,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('failed start() and dispose() futures stay inside the SDK', (
    tester,
  ) async {
    final healthy = _RecordingSink();
    await _mountAndUnmount(tester, [_FailingSink(async: true), healthy]);

    expect(healthy.types, contains('session_start'));
    expect(healthy.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed typed future (Future<bool> as Future<void>) stays '
      'inside the SDK', (tester) async {
    final healthy = _RecordingSink();
    await _mountAndUnmount(tester, [_FailingSink.typed(), healthy]);

    expect(healthy.types, contains('session_start'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('synchronous throws from start() and dispose() stay inside '
      'the SDK', (tester) async {
    final healthy = _RecordingSink();
    await _mountAndUnmount(tester, [_FailingSink(async: false), healthy]);

    expect(healthy.types, contains('session_start'));
    expect(healthy.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a sink factory that throws is skipped and capture still starts',
    (tester) async {
      final healthy = _RecordingSink();
      await tester.pumpWidget(_app([_ThrowingFactory(), healthy]));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(TugboatReplay.controller?.session, isNotNull);
      expect(healthy.started, isTrue);
      expect(healthy.types, contains('session_start'));
    },
  );
}

Widget _app(List<TugboatCaptureSinkFactory> sinks) => MaterialApp(
  builder: (context, child) => TugboatReplay.wrapApp(
    config: _config.copyWith(sinkFactories: sinks),
    child: child!,
  ),
  home: const SizedBox.expand(),
);

Future<void> _mountAndUnmount(
  WidgetTester tester,
  List<TugboatCaptureSinkFactory> sinks,
) async {
  await tester.pumpWidget(_app(sinks));
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pump(const Duration(seconds: 6));
}

class _RecordingSink extends TugboatSessionCaptureSink
    implements TugboatCaptureSinkFactory {
  final types = <String>[];
  bool started = false;
  bool disposed = false;

  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) => this;

  @override
  void accept(TugboatCaptureEnvelope envelope) {
    final event = envelope.event;
    if (event != null) types.add(event.type);
  }

  @override
  Future<void> start(TugboatSinkSessionContext context) async {
    started = true;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> finish() async {}

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// Fails in start() and dispose(), as a failed future or a synchronous throw.
class _FailingSink extends TugboatSessionCaptureSink
    implements TugboatCaptureSinkFactory {
  _FailingSink({required this.async}) : typed = false;

  /// Returns a failing `Future<bool>`, as a sink that forwards a typed write
  /// (`prefs.setString(...)`) from start() or dispose() would.
  _FailingSink.typed() : async = true, typed = true;

  final bool async;
  final bool typed;

  Future<void> _fail(String call) {
    final error = StateError('sink $call failed');
    if (typed) return Future<bool>.error(error);
    if (async) return Future.error(error);
    throw error;
  }

  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) => this;

  @override
  void accept(TugboatCaptureEnvelope envelope) {}

  @override
  Future<void> start(TugboatSinkSessionContext context) => _fail('start');

  @override
  Future<void> flush() async {}

  @override
  Future<void> finish() async {}

  @override
  Future<void> dispose() => _fail('dispose');
}

class _ThrowingFactory implements TugboatCaptureSinkFactory {
  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) =>
      throw StateError('sink factory failed');
}
