import 'dart:async';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

import 'perceptual_hash.dart';

/// JPEG quality for emitted frames. Screenshots are photo-heavy once masking
/// is relaxed, where JPEG is ~5x smaller than PNG at comparable legibility.
const int screenshotJpegQuality = 80;

/// Encoded JPEG bytes plus hashes used for coalesce / session dedup.
class ScreenshotEncodeResult {
  const ScreenshotEncodeResult({
    required this.bytes,
    required this.contentHash,
    this.dHash,
    this.skippedByDHash = false,
  });

  final Uint8List bytes;
  final String contentHash;
  final String? dHash;
  final bool skippedByDHash;
}

class _ComputeEncodeRequest {
  const _ComputeEncodeRequest({
    required this.rgba,
    required this.width,
    required this.height,
    required this.maskRects,
    required this.lastDHash,
    required this.force,
  });

  final Uint8List rgba;
  final int width;
  final int height;

  /// Pixel-space mask rectangles as flat `[left, top, right, bottom, ...]`.
  final Float64List maskRects;
  final String? lastDHash;
  final bool force;
}

ScreenshotEncodeResult _encodeJpegCompute(_ComputeEncodeRequest request) {
  return _encodeJpegBytes(
    rgba: request.rgba,
    width: request.width,
    height: request.height,
    maskRects: request.maskRects,
    lastDHash: request.lastDHash,
    force: request.force,
  );
}

/// Dark fill used for masked regions (matches the previous canvas mask color).
const int _maskFillR = 0x1a;
const int _maskFillG = 0x1a;
const int _maskFillB = 0x1a;
const int _maskFillA = 0xff;

void _applyMaskRectsInPlace({
  required Uint8List rgba,
  required int width,
  required int height,
  required Float64List maskRects,
}) {
  if (maskRects.isEmpty) return;
  for (var i = 0; i + 3 < maskRects.length; i += 4) {
    final left = maskRects[i].floor().clamp(0, width);
    final top = maskRects[i + 1].floor().clamp(0, height);
    final right = maskRects[i + 2].ceil().clamp(0, width);
    final bottom = maskRects[i + 3].ceil().clamp(0, height);
    if (right <= left || bottom <= top) continue;
    for (var y = top; y < bottom; y++) {
      var offset = (y * width + left) * 4;
      for (var x = left; x < right; x++) {
        rgba[offset] = _maskFillR;
        rgba[offset + 1] = _maskFillG;
        rgba[offset + 2] = _maskFillB;
        rgba[offset + 3] = _maskFillA;
        offset += 4;
      }
    }
  }
}

ScreenshotEncodeResult _encodeJpegBytes({
  required Uint8List rgba,
  required int width,
  required int height,
  Float64List? maskRects,
  String? lastDHash,
  bool force = false,
}) {
  if (maskRects != null && maskRects.isNotEmpty) {
    _applyMaskRectsInPlace(
      rgba: rgba,
      width: width,
      height: height,
      maskRects: maskRects,
    );
  }
  final dHash = computeDHashFromRgba(rgba, width, height);
  if (!force && dHashVisuallyMatches(lastDHash, dHash)) {
    return ScreenshotEncodeResult(
      bytes: Uint8List(0),
      contentHash: '',
      dHash: dHash,
      skippedByDHash: true,
    );
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    rowStride: width * 4,
    order: img.ChannelOrder.rgba,
  );
  final jpeg = Uint8List.fromList(
    img.encodeJpg(image, quality: screenshotJpegQuality),
  );
  return ScreenshotEncodeResult(
    bytes: jpeg,
    contentHash: sha256.convert(jpeg).toString(),
    dHash: dHash.isEmpty ? null : dHash,
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

/// Long-lived encode worker that keeps mask fills, dHash, JPEG, and SHA-256
/// off the UI isolate. RGBA is accepted via [TransferableTypedData] to avoid a
/// second full-frame copy into the worker.
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
    if (message is! List || message.length < 5) return;
    final jobId = message[0];
    if (jobId is! int) return;
    final pending = _pending.remove(jobId);
    if (pending == null || pending.isCompleted) return;
    final error = message[4];
    if (error is String) {
      pending.completeError(StateError(error));
      return;
    }
    final bytes = message[1];
    final contentHash = message[2];
    final dHash = message[3];
    final skipped = message.length > 5 ? message[5] == true : false;
    if (bytes is! Uint8List || contentHash is! String) {
      pending.completeError(StateError('encode reply missing payload'));
      return;
    }
    pending.complete(
      ScreenshotEncodeResult(
        bytes: bytes,
        contentHash: contentHash,
        dHash: dHash is String && dHash.isNotEmpty ? dHash : null,
        skippedByDHash: skipped,
      ),
    );
  }

  /// Masks, dHashes, and optionally JPEG-encodes [rgba].
  ///
  /// [maskRects] is an optional flat list of pixel-space rectangles
  /// (`left, top, right, bottom` repeating) painted as opaque dark fills
  /// before hashing/encoding. When [force] is false and the masked dHash
  /// matches [lastDHash], JPEG encoding is skipped.
  Future<ScreenshotEncodeResult> encode({
    required Uint8List rgba,
    required int width,
    required int height,
    Float64List? maskRects,
    String? lastDHash,
    bool force = false,
  }) async {
    if (_disposed) {
      throw StateError('ScreenshotEncodeIsolate is disposed');
    }
    final masks = maskRects ?? Float64List(0);
    if (_underWidgetTestBinding()) {
      return compute(
        _encodeJpegCompute,
        _ComputeEncodeRequest(
          rgba: rgba,
          width: width,
          height: height,
          maskRects: masks,
          lastDHash: lastDHash,
          force: force,
        ),
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
      masks,
      lastDHash,
      force,
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
    if (message is! List || message.length != 7) return;
    final jobId = message[0];
    final transferable = message[1];
    final width = message[2];
    final height = message[3];
    final maskRects = message[4];
    final lastDHash = message[5];
    final force = message[6];
    if (jobId is! int ||
        transferable is! TransferableTypedData ||
        width is! int ||
        height is! int ||
        maskRects is! Float64List ||
        (lastDHash != null && lastDHash is! String) ||
        force is! bool) {
      return;
    }
    try {
      final rgba = transferable.materialize().asUint8List();
      final encoded = _encodeJpegBytes(
        rgba: rgba,
        width: width,
        height: height,
        maskRects: maskRects,
        lastDHash: lastDHash as String?,
        force: force,
      );
      replyTo.send(<Object?>[
        jobId,
        encoded.bytes,
        encoded.contentHash,
        encoded.dHash,
        null,
        encoded.skippedByDHash,
      ]);
    } catch (error) {
      replyTo.send(<Object?>[jobId, null, null, null, error.toString(), false]);
    }
  });
}
