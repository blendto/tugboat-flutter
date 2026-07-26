import 'dart:async';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:image/image.dart' as img;

import 'anchors.dart';
import 'capture_boundary.dart';
import 'perceptual_hash.dart';
import 'screenshot_mask_level.dart';

/// JPEG quality for emitted frames. Screenshots are photo-heavy once masking
/// is relaxed, where JPEG is ~5x smaller than PNG at comparable legibility.
const int _jpegQuality = 80;

/// Why a screenshot request could not produce a fresh rendered observation.
///
/// This remains an internal capture detail: callers continue to receive a
/// nullable frame, while the controller uses the reason for health/debug
/// evidence and, crucially, never turns one of these outcomes into a stale
/// forced frame.
enum ScreenshotCaptureFailure {
  boundaryUnavailable,
  boundaryDetached,
  boundaryReplaced,
  layoutUnavailable,
  paintTimedOut,
  paintNotAdvanced,
  cancelled,
  readbackFailed,
  maskFailed,
  encodingFailed,
}

enum _FrameWaitOutcome { completed, timedOut, cancelled }

class _ScreenshotCaptureException implements Exception {
  const _ScreenshotCaptureException(this.failure);

  final ScreenshotCaptureFailure failure;
}

class ScreenshotCaptureAttempt {
  const ScreenshotCaptureAttempt({
    this.result,
    this.failure,
    this.frameWaitMicros = 0,
  }) : assert(result != null || failure != null);

  final ScreenshotCaptureResult? result;
  final ScreenshotCaptureFailure? failure;
  final int frameWaitMicros;
}

class _JpegEncodeRequest {
  const _JpegEncodeRequest(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

Uint8List _encodeJpeg(_JpegEncodeRequest request) {
  final image = img.Image.fromBytes(
    width: request.width,
    height: request.height,
    bytes: request.rgba.buffer,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: _jpegQuality));
}

class MaskRect {
  const MaskRect(this.rect);

  final Rect rect;
}

class ScreenshotCaptureResult {
  const ScreenshotCaptureResult({
    required this.bytes,
    required this.contentHash,
    this.dHash,
    required this.width,
    required this.height,
    required this.boundaryLogicalRect,
    required this.masked,
    required this.captureMicros,
    required this.encodeMicros,
    this.maskMicros = 0,
    this.skippedByDHash = false,
  });

  final Uint8List bytes;
  final String contentHash;
  final String? dHash;
  final int width;
  final int height;
  final Rect boundaryLogicalRect;
  final bool masked;
  final int captureMicros;
  final int encodeMicros;
  final int maskMicros;
  final bool skippedByDHash;
}

class ScreenshotCapturer {
  ScreenshotCapturer({
    required this.boundaryKey,
    required this.maskLevel,
    required this.anchorResolver,
    this.pixelRatio = 0.75,
    @visibleForTesting Future<void> Function()? frameWaiter,
  }) : _frameWaiter =
           frameWaiter ?? (() => SchedulerBinding.instance.endOfFrame);

  final GlobalKey boundaryKey;
  final double pixelRatio;
  final TugboatScreenshotMaskLevel maskLevel;
  final Future<void> Function() _frameWaiter;

  /// Shared resolver used for frame-scoped element maps when masking.
  final AnchorResolver anchorResolver;

  String? _lastDHash;

  /// Wait for one bounded compositor opportunity.  The timeout does not try
  /// to cancel Flutter's frame future (which is shared by the binding); it
  /// merely releases this capture request and later fences the stale waiter.
  Future<_FrameWaitOutcome> _waitForFrameBudget({
    Duration timeout = const Duration(seconds: 2),
    Future<void>? cancelled,
  }) async {
    final outcome = Completer<_FrameWaitOutcome>();
    void complete(_FrameWaitOutcome value) {
      if (!outcome.isCompleted) outcome.complete(value);
    }

    final timeoutTimer = Timer(
      timeout,
      () => complete(_FrameWaitOutcome.timedOut),
    );
    unawaited(
      _frameWaiter().then(
        (_) => complete(_FrameWaitOutcome.completed),
        onError: (_, __) => complete(_FrameWaitOutcome.completed),
      ),
    );
    if (cancelled != null) {
      unawaited(cancelled.then((_) => complete(_FrameWaitOutcome.cancelled)));
    }
    try {
      return await outcome.future;
    } finally {
      timeoutTimer.cancel();
    }
  }

  ScreenshotCaptureFailure? _boundaryFailure(
    RenderRepaintBoundary? requestedBoundary,
  ) {
    final currentContext = boundaryKey.currentContext;
    if (currentContext == null) {
      return requestedBoundary == null
          ? ScreenshotCaptureFailure.boundaryUnavailable
          : ScreenshotCaptureFailure.boundaryDetached;
    }
    if (!currentContext.mounted) {
      return ScreenshotCaptureFailure.boundaryDetached;
    }
    final currentBoundary = currentContext.findRenderObject();
    if (currentBoundary is! RenderRepaintBoundary ||
        !currentBoundary.isRepaintBoundary) {
      return ScreenshotCaptureFailure.boundaryUnavailable;
    }
    if (requestedBoundary != null &&
        !identical(currentBoundary, requestedBoundary)) {
      return ScreenshotCaptureFailure.boundaryReplaced;
    }
    if (!currentBoundary.attached) {
      return ScreenshotCaptureFailure.boundaryDetached;
    }
    if (!currentBoundary.hasSize) {
      return ScreenshotCaptureFailure.layoutUnavailable;
    }
    return null;
  }

  /// Captures a frame together with a classified outcome.  Fresh attempts
  /// snapshot the exact boundary before waiting; a remount during that wait is
  /// a failure, never permission to read a previous layer or a replacement.
  Future<ScreenshotCaptureAttempt> captureAttempt({
    String? lastDHash,
    bool force = false,
    bool waitForFrame = true,
    bool requireFreshPaint = false,
    Duration frameTimeout = const Duration(seconds: 2),
    bool Function()? isCurrent,
    Future<void>? cancelled,
  }) async {
    if (isCurrent != null && !isCurrent()) {
      return const ScreenshotCaptureAttempt(
        failure: ScreenshotCaptureFailure.cancelled,
      );
    }
    final requestedObject = boundaryKey.currentContext?.findRenderObject();
    final requestedBoundary = requestedObject is RenderRepaintBoundary
        ? requestedObject
        : null;
    final beforeWaitFailure = _boundaryFailure(requestedBoundary);
    if (beforeWaitFailure != null) {
      return ScreenshotCaptureAttempt(failure: beforeWaitFailure);
    }

    final paintGeneration = requestedBoundary is TugboatCaptureRenderBoundary
        ? requestedBoundary.paintGeneration
        : null;
    if (requireFreshPaint) {
      if (requestedBoundary is! TugboatCaptureRenderBoundary) {
        return const ScreenshotCaptureAttempt(
          failure: ScreenshotCaptureFailure.paintNotAdvanced,
        );
      }
      final paintFailure = _boundaryFailure(requestedBoundary);
      if (paintFailure != null) {
        return ScreenshotCaptureAttempt(failure: paintFailure);
      }
      try {
        requestedBoundary.markNeedsPaint();
        SchedulerBinding.instance.ensureVisualUpdate();
      } on FlutterError {
        return const ScreenshotCaptureAttempt(
          failure: ScreenshotCaptureFailure.boundaryDetached,
        );
      }
    }

    var frameWaitMicros = 0;
    if (waitForFrame || requireFreshPaint) {
      final waitClock = Stopwatch()..start();
      final waitOutcome = await _waitForFrameBudget(
        timeout: frameTimeout,
        cancelled: cancelled,
      );
      waitClock.stop();
      frameWaitMicros = waitClock.elapsedMicroseconds;
      if (waitOutcome == _FrameWaitOutcome.cancelled) {
        return ScreenshotCaptureAttempt(
          failure: ScreenshotCaptureFailure.cancelled,
          frameWaitMicros: frameWaitMicros,
        );
      }
      if (waitOutcome == _FrameWaitOutcome.timedOut) {
        return ScreenshotCaptureAttempt(
          failure: ScreenshotCaptureFailure.paintTimedOut,
          frameWaitMicros: frameWaitMicros,
        );
      }
    }
    if (isCurrent != null && !isCurrent()) {
      return ScreenshotCaptureAttempt(
        failure: ScreenshotCaptureFailure.cancelled,
        frameWaitMicros: frameWaitMicros,
      );
    }

    final afterWaitFailure = _boundaryFailure(requestedBoundary);
    if (afterWaitFailure != null) {
      return ScreenshotCaptureAttempt(
        failure: afterWaitFailure,
        frameWaitMicros: frameWaitMicros,
      );
    }
    if (requireFreshPaint) {
      final currentBoundary = boundaryKey.currentContext?.findRenderObject();
      final advanced = currentBoundary is TugboatCaptureRenderBoundary
          ? paintGeneration != null &&
                currentBoundary.paintGeneration > paintGeneration
          : false;
      if (!advanced) {
        return ScreenshotCaptureAttempt(
          failure: ScreenshotCaptureFailure.paintNotAdvanced,
          frameWaitMicros: frameWaitMicros,
        );
      }
    }

    try {
      // Reacquire after the async boundary check. The identity check above
      // proves this is the same mounted boundary we observed before waiting.
      final currentContext = boundaryKey.currentContext;
      if (currentContext is! Element) {
        return ScreenshotCaptureAttempt(
          failure: ScreenshotCaptureFailure.boundaryDetached,
          frameWaitMicros: frameWaitMicros,
        );
      }
      final currentBoundary =
          currentContext.findRenderObject() as RenderRepaintBoundary;
      final result = await _captureReadyBoundary(
        // This Element was reacquired after the async wait and validated
        // against the original boundary identity immediately above.
        // ignore: use_build_context_synchronously
        currentContext,
        currentBoundary,
        lastDHash: lastDHash,
        force: force,
      );
      if (isCurrent != null && !isCurrent()) {
        return ScreenshotCaptureAttempt(
          failure: ScreenshotCaptureFailure.cancelled,
          frameWaitMicros: frameWaitMicros,
        );
      }
      if (result == null) {
        return ScreenshotCaptureAttempt(
          failure: ScreenshotCaptureFailure.encodingFailed,
          frameWaitMicros: frameWaitMicros,
        );
      }
      return ScreenshotCaptureAttempt(
        result: result,
        frameWaitMicros: frameWaitMicros,
      );
    } on _ScreenshotCaptureException catch (error) {
      return ScreenshotCaptureAttempt(
        failure: error.failure,
        frameWaitMicros: frameWaitMicros,
      );
    } catch (_) {
      return ScreenshotCaptureAttempt(
        failure: ScreenshotCaptureFailure.readbackFailed,
        frameWaitMicros: frameWaitMicros,
      );
    }
  }

  Future<ScreenshotCaptureResult?> capture({
    String? lastDHash,
    bool force = false,
    bool waitForFrame = true,
  }) async => (await captureAttempt(
    lastDHash: lastDHash,
    force: force,
    waitForFrame: waitForFrame,
  )).result;

  Future<ScreenshotCaptureResult?> _captureReadyBoundary(
    Element context,
    RenderRepaintBoundary boundary, {
    required String? lastDHash,
    required bool force,
  }) async {
    final rootRender = boundary;
    final boundaryOrigin = boundary.localToGlobal(Offset.zero);
    final boundaryLogicalRect = boundaryOrigin & boundary.size;

    final List<MaskRect> maskRects;
    final maskClock = Stopwatch()..start();
    try {
      maskRects = _collectMaskRects(context, rootRender);
    } catch (_) {
      throw const _ScreenshotCaptureException(
        ScreenshotCaptureFailure.maskFailed,
      );
    } finally {
      maskClock.stop();
    }

    final ui.Image image;
    final readbackClock = Stopwatch()..start();
    try {
      image = await boundary.toImage(pixelRatio: pixelRatio);
    } catch (_) {
      throw const _ScreenshotCaptureException(
        ScreenshotCaptureFailure.readbackFailed,
      );
    } finally {
      readbackClock.stop();
    }
    try {
      final scaledWidth = image.width;
      final scaledHeight = image.height;
      ui.Image rasterImage = image;

      var maskMicros = maskClock.elapsedMicroseconds;
      if (maskRects.isNotEmpty) {
        maskClock
          ..reset()
          ..start();
        try {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawImage(image, Offset.zero, Paint());

          final maskPaint = Paint()..color = const Color(0xFF1A1A1A);
          for (final mask in maskRects) {
            final scaled = Rect.fromLTWH(
              mask.rect.left * pixelRatio,
              mask.rect.top * pixelRatio,
              mask.rect.width * pixelRatio,
              mask.rect.height * pixelRatio,
            );
            if (scaled.width > 0 && scaled.height > 0) {
              canvas.drawRect(scaled, maskPaint);
            }
          }

          final picture = recorder.endRecording();
          try {
            rasterImage = await picture.toImage(scaledWidth, scaledHeight);
          } finally {
            picture.dispose();
          }
        } catch (_) {
          throw const _ScreenshotCaptureException(
            ScreenshotCaptureFailure.maskFailed,
          );
        } finally {
          maskClock.stop();
          maskMicros += maskClock.elapsedMicroseconds;
        }
      }

      try {
        final encodeClock = Stopwatch()..start();
        try {
          final quickDHash = await _dHashFromThumbnail(rasterImage);
          final compareDHash = lastDHash ?? _lastDHash;
          if (!force &&
              quickDHash != null &&
              compareDHash != null &&
              quickDHash == compareDHash) {
            return ScreenshotCaptureResult(
              bytes: Uint8List(0),
              contentHash: '',
              dHash: quickDHash,
              width: scaledWidth,
              height: scaledHeight,
              boundaryLogicalRect: boundaryLogicalRect,
              masked: maskRects.isNotEmpty,
              captureMicros: readbackClock.elapsedMicroseconds,
              encodeMicros: encodeClock.elapsedMicroseconds,
              maskMicros: maskMicros,
              skippedByDHash: true,
            );
          }

          final byteData = await rasterImage.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (byteData == null) {
            throw const _ScreenshotCaptureException(
              ScreenshotCaptureFailure.encodingFailed,
            );
          }
          final jpeg = await compute(
            _encodeJpeg,
            _JpegEncodeRequest(
              byteData.buffer.asUint8List(),
              scaledWidth,
              scaledHeight,
            ),
          );
          final contentHash = sha256.convert(jpeg).toString();
          if (quickDHash != null) {
            _lastDHash = quickDHash;
          }
          return ScreenshotCaptureResult(
            bytes: jpeg,
            contentHash: contentHash,
            dHash: quickDHash,
            width: scaledWidth,
            height: scaledHeight,
            boundaryLogicalRect: boundaryLogicalRect,
            masked: maskRects.isNotEmpty,
            captureMicros: readbackClock.elapsedMicroseconds,
            encodeMicros: encodeClock.elapsedMicroseconds,
            maskMicros: maskMicros,
          );
        } on _ScreenshotCaptureException {
          rethrow;
        } catch (_) {
          throw const _ScreenshotCaptureException(
            ScreenshotCaptureFailure.encodingFailed,
          );
        } finally {
          encodeClock.stop();
        }
      } finally {
        if (!identical(rasterImage, image)) {
          rasterImage.dispose();
        }
      }
    } finally {
      image.dispose();
    }
  }

  Future<String?> _dHashFromThumbnail(ui.Image source) async {
    const hashWidth = 9;
    const hashHeight = 8;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, hashWidth.toDouble(), hashHeight.toDouble()),
      Paint()..filterQuality = FilterQuality.low,
    );
    final picture = recorder.endRecording();
    final ui.Image thumb;
    try {
      thumb = await picture.toImage(hashWidth, hashHeight);
    } finally {
      picture.dispose();
    }
    try {
      final bytes = await thumb.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return null;
      return computeDHashFromRgba(
        bytes.buffer.asUint8List(),
        hashWidth,
        hashHeight,
      );
    } finally {
      thumb.dispose();
    }
  }

  List<MaskRect> _collectMaskRects(Element root, RenderBox ancestor) {
    return anchorResolver
        .collectMaskRects(rootRender: ancestor, shouldMask: _shouldMask)
        .map(MaskRect.new)
        .toList();
  }

  bool _shouldMask(
    Element element,
    Widget widget,
    RenderBox renderObject,
    bool explicitlySensitive,
    bool actionable,
  ) {
    if (explicitlySensitive) return true;

    final isText = renderObject is RenderParagraph;
    final isTextInput = widget is EditableText;
    final isMedia = renderObject is RenderImage;
    final isSensitiveInput =
        widget is EditableText && tugboatIsSensitiveInput(widget);

    return switch (maskLevel) {
      TugboatScreenshotMaskLevel.explicitOnly => false,
      TugboatScreenshotMaskLevel.allTextAndMedia =>
        isText || isTextInput || isMedia,
      TugboatScreenshotMaskLevel.allText => isText || isTextInput,
      TugboatScreenshotMaskLevel.allTextExceptActionable =>
        isSensitiveInput || ((isText || isTextInput) && !actionable),
      TugboatScreenshotMaskLevel.sensitiveInputsOnly => isSensitiveInput,
      TugboatScreenshotMaskLevel.nonAssetImagesOnly =>
        isSensitiveInput || (isMedia && _isNonAssetImageWidget(element)),
    };
  }

  /// Image provenance for `nonAssetImagesOnly`: whether the
  /// [RenderImage]-owning [element] renders anything other than a bundled
  /// asset. This is the single place to extend image classification.
  ///
  /// `Image` builds a `RawImage` whose `ui.Image` carries no provenance, so
  /// the provider is recovered from the nearest `Image` ancestor. Anything
  /// without a resolvable asset provider (network, file, memory, or
  /// third-party providers like cached/extended network images) is treated
  /// as user content and masked.
  bool _isNonAssetImageWidget(Element element) {
    ImageProvider? provider;
    final widget = element.widget;
    if (widget is Image) {
      provider = widget.image;
    } else {
      var hops = 0;
      element.visitAncestorElements((ancestor) {
        final ancestorWidget = ancestor.widget;
        if (ancestorWidget is Image) {
          provider = ancestorWidget.image;
          return false;
        }
        return ++hops < 16;
      });
    }
    final resolved = provider;
    if (resolved == null) return true;
    return !_providerIsAsset(resolved);
  }

  bool _providerIsAsset(ImageProvider provider) {
    if (provider is ResizeImage) {
      return _providerIsAsset(provider.imageProvider);
    }
    return provider is AssetBundleImageProvider;
  }
}
