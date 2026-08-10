import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'screenshot_encode.dart';

class ScreenshotEncodeIsolateCommand {
  const ScreenshotEncodeIsolateCommand({
    required this.jobId,
    required this.rgba,
    required this.width,
    required this.height,
    required this.maskRects,
    this.lastDHash,
    required this.force,
  });

  final int jobId;
  final TransferableTypedData rgba;
  final int width;
  final int height;
  final Float64List maskRects;
  final String? lastDHash;
  final bool force;
}

class ScreenshotEncodeIsolateReply {
  const ScreenshotEncodeIsolateReply._({
    required this.jobId,
    this.result,
    this.message,
  });

  const ScreenshotEncodeIsolateReply.success({
    required int jobId,
    required ScreenshotEncodeResult result,
  }) : this._(jobId: jobId, result: result);

  const ScreenshotEncodeIsolateReply.failure({
    required int jobId,
    required String message,
  }) : this._(jobId: jobId, message: message);

  final int jobId;
  final ScreenshotEncodeResult? result;
  final String? message;

  bool get isSuccess => result != null;
}

ScreenshotEncodeResult _encodeInCompute(ScreenshotEncodeInput input) {
  return encodeScreenshotRgba(input);
}

/// [compute]-based encoder for tests that need async completion without a
/// persistent isolate (for example under FakeAsync).
class ComputeScreenshotEncoder implements ScreenshotEncoder {
  @override
  Future<ScreenshotEncodeResult> encode(ScreenshotEncodeInput input) {
    return compute(_encodeInCompute, input);
  }

  @override
  Future<void> dispose() => Future<void>.value();
}

/// Production encoder backed by a persistent isolate with
/// [TransferableTypedData] transport.
class IsolateScreenshotEncoder implements ScreenshotEncoder {
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _starting;
  var _nextJobId = 0;
  final Map<int, Completer<ScreenshotEncodeResult>> _pending =
      <int, Completer<ScreenshotEncodeResult>>{};
  var _disposed = false;

  /// Ensures the worker isolate is running. Safe to call repeatedly.
  Future<void> ensureStarted() async {
    if (_disposed) {
      throw StateError('IsolateScreenshotEncoder is disposed');
    }
    if (_commands != null) return;
    final inFlight = _starting;
    if (inFlight != null) {
      await inFlight.future;
      if (_disposed) {
        throw StateError('IsolateScreenshotEncoder is disposed');
      }
      return;
    }
    final starting = Completer<void>();
    _starting = starting;
    try {
      final handshake = Completer<SendPort>();
      final responses = ReceivePort();
      _responses = responses;
      _subscription = responses.listen((message) {
        if (!handshake.isCompleted && message is SendPort) {
          handshake.complete(message);
          return;
        }
        _onReply(message);
      });
      _isolate = await Isolate.spawn(
        _screenshotEncodeIsolateMain,
        responses.sendPort,
        debugName: 'tugboat-screenshot-encode',
      );
      final commands = await handshake.future.timeout(
        const Duration(seconds: 5),
      );
      if (_disposed) {
        await _tearDown();
        throw StateError('IsolateScreenshotEncoder is disposed');
      }
      _commands = commands;
      starting.complete();
    } catch (error, stack) {
      if (!starting.isCompleted) {
        starting.completeError(error, stack);
      }
      await _tearDown();
      rethrow;
    } finally {
      if (identical(_starting, starting)) {
        _starting = null;
      }
    }
  }

  void _onReply(dynamic message) {
    if (message is! ScreenshotEncodeIsolateReply) {
      _failAllPending(
        StateError('encode reply had unexpected type: ${message.runtimeType}'),
      );
      return;
    }
    final pending = _pending.remove(message.jobId);
    if (pending == null || pending.isCompleted) return;
    if (message.isSuccess) {
      pending.complete(message.result!);
      return;
    }
    pending.completeError(
      StateError(message.message ?? 'encode reply missing error detail'),
    );
  }

  void _failAllPending(Object error) {
    final pending = Map<int, Completer<ScreenshotEncodeResult>>.from(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }

  @override
  Future<ScreenshotEncodeResult> encode(ScreenshotEncodeInput input) async {
    if (_disposed) {
      throw StateError('IsolateScreenshotEncoder is disposed');
    }
    await ensureStarted();
    if (_disposed) {
      throw StateError('IsolateScreenshotEncoder is disposed');
    }
    final commands = _commands;
    if (commands == null) {
      throw StateError('IsolateScreenshotEncoder failed to start');
    }
    final jobId = _nextJobId++;
    final completer = Completer<ScreenshotEncodeResult>();
    _pending[jobId] = completer;
    // fromList copies once into a transferable buffer on this isolate; the
    // worker then materializes without a second full-frame copy. This still
    // pays one sender-side memcpy versus keeping pixels in shared storage.
    commands.send(
      ScreenshotEncodeIsolateCommand(
        jobId: jobId,
        rgba: TransferableTypedData.fromList([input.rgba]),
        width: input.width,
        height: input.height,
        maskRects: input.maskRectsOrEmpty,
        lastDHash: input.lastDHash,
        force: input.force,
      ),
    );
    return completer.future;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _failAllPending(StateError('IsolateScreenshotEncoder disposed'));
    await _tearDown();
  }

  Future<void> _tearDown() async {
    await _subscription?.cancel();
    _subscription = null;
    _responses?.close();
    _responses = null;
    _commands = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

@pragma('vm:entry-point')
void _screenshotEncodeIsolateMain(SendPort replyTo) {
  final commands = ReceivePort();
  replyTo.send(commands.sendPort);
  commands.listen((message) {
    if (message is! ScreenshotEncodeIsolateCommand) {
      return;
    }
    try {
      final rgba = message.rgba.materialize().asUint8List();
      final encoded = encodeScreenshotRgba(
        ScreenshotEncodeInput(
          rgba: rgba,
          width: message.width,
          height: message.height,
          maskRects: message.maskRects,
          lastDHash: message.lastDHash,
          force: message.force,
        ),
      );
      replyTo.send(
        ScreenshotEncodeIsolateReply.success(jobId: message.jobId, result: encoded),
      );
    } catch (error) {
      replyTo.send(
        ScreenshotEncodeIsolateReply.failure(
          jobId: message.jobId,
          message: error.toString(),
        ),
      );
    }
  });
}
