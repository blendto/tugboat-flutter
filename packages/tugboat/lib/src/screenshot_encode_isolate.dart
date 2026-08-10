import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

/// JPEG quality for emitted frames. Screenshots are photo-heavy once masking
/// is relaxed, where JPEG is ~5x smaller than PNG at comparable legibility.
const int screenshotJpegQuality = 80;

/// Encoded JPEG bytes plus the content hash used for session dedup.
class ScreenshotEncodeResult {
  const ScreenshotEncodeResult({
    required this.bytes,
    required this.contentHash,
  });

  final Uint8List bytes;
  final String contentHash;
}

class _ComputeEncodeRequest {
  const _ComputeEncodeRequest(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

ScreenshotEncodeResult _encodeJpegCompute(_ComputeEncodeRequest request) {
  return _encodeJpegBytes(
    rgba: request.rgba,
    width: request.width,
    height: request.height,
  );
}

ScreenshotEncodeResult _encodeJpegBytes({
  required Uint8List rgba,
  required int width,
  required int height,
}) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    order: img.ChannelOrder.rgba,
  );
  final jpeg = Uint8List.fromList(
    img.encodeJpg(image, quality: screenshotJpegQuality),
  );
  return ScreenshotEncodeResult(
    bytes: jpeg,
    contentHash: sha256.convert(jpeg).toString(),
  );
}

bool _underWidgetTestBinding() {
  try {
    return WidgetsBinding.instance.runtimeType.toString().contains(
      'TestWidgetsFlutterBinding',
    );
  } catch (_) {
    return false;
  }
}

/// Long-lived encode worker that keeps JPEG + SHA-256 off the UI isolate and
/// accepts RGBA pixels via [TransferableTypedData] to avoid a second full-frame
/// copy into the worker.
///
/// Under `testWidgets` FakeAsync, ReceivePort replies are not pumped unless
/// callers wrap awaits in `tester.runAsync`. Those tests fall back to
/// [compute], which completes through the same path the suite already used.
class ScreenshotEncodeIsolate {
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
      throw StateError('ScreenshotEncodeIsolate is disposed');
    }
    if (_underWidgetTestBinding()) return;
    if (_commands != null) return;
    final inFlight = _starting;
    if (inFlight != null) {
      await inFlight.future;
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
      _commands = await handshake.future.timeout(const Duration(seconds: 5));
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
    if (message is! List || message.length < 3) return;
    final jobId = message[0];
    if (jobId is! int) return;
    final pending = _pending.remove(jobId);
    if (pending == null || pending.isCompleted) return;
    final error = message.length > 3 ? message[3] : null;
    if (error is String) {
      pending.completeError(StateError(error));
      return;
    }
    final bytes = message[1];
    final contentHash = message[2];
    if (bytes is! Uint8List || contentHash is! String) {
      pending.completeError(StateError('encode reply missing payload'));
      return;
    }
    pending.complete(
      ScreenshotEncodeResult(bytes: bytes, contentHash: contentHash),
    );
  }

  /// Encodes [rgba] (straight RGBA) to JPEG and returns bytes + SHA-256.
  Future<ScreenshotEncodeResult> encode({
    required Uint8List rgba,
    required int width,
    required int height,
  }) async {
    if (_disposed) {
      throw StateError('ScreenshotEncodeIsolate is disposed');
    }
    if (_underWidgetTestBinding()) {
      return compute(
        _encodeJpegCompute,
        _ComputeEncodeRequest(rgba, width, height),
      );
    }
    await ensureStarted();
    final commands = _commands;
    if (commands == null) {
      throw StateError('ScreenshotEncodeIsolate failed to start');
    }
    final jobId = _nextJobId++;
    final completer = Completer<ScreenshotEncodeResult>();
    _pending[jobId] = completer;
    commands.send(<Object?>[
      jobId,
      TransferableTypedData.fromList([rgba]),
      width,
      height,
    ]);
    return completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final pending = Map<int, Completer<ScreenshotEncodeResult>>.from(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('ScreenshotEncodeIsolate disposed'));
      }
    }
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
    if (message is! List || message.length != 4) return;
    final jobId = message[0];
    final transferable = message[1];
    final width = message[2];
    final height = message[3];
    if (jobId is! int ||
        transferable is! TransferableTypedData ||
        width is! int ||
        height is! int) {
      return;
    }
    try {
      final rgba = transferable.materialize().asUint8List();
      final encoded = _encodeJpegBytes(
        rgba: rgba,
        width: width,
        height: height,
      );
      replyTo.send(<Object?>[jobId, encoded.bytes, encoded.contentHash]);
    } catch (error) {
      replyTo.send(<Object?>[jobId, null, null, error.toString()]);
    }
  });
}
