import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'anchors.dart';
import 'perceptual_hash.dart';
import 'screenshot_mask_level.dart';

class MaskRect {
  const MaskRect(this.rect);

  final Rect rect;
}

class ScreenshotCaptureResult {
  const ScreenshotCaptureResult({
    required this.bytes,
    required this.contentHash,
    required this.dHash,
    required this.width,
    required this.height,
    required this.masked,
    required this.captureMicros,
    required this.encodeMicros,
    this.skippedByDHash = false,
  });

  final Uint8List bytes;
  final String contentHash;
  final String dHash;
  final int width;
  final int height;
  final bool masked;
  final int captureMicros;
  final int encodeMicros;
  final bool skippedByDHash;
}

class ScreenshotCapturer {
  ScreenshotCapturer({
    required this.boundaryKey,
    required this.maskLevel,
    required this.anchorResolver,
    this.pixelRatio = 0.75,
  });

  final GlobalKey boundaryKey;
  final double pixelRatio;
  final TugboatScreenshotMaskLevel maskLevel;

  /// Shared resolver used for frame-scoped element maps when masking.
  final AnchorResolver anchorResolver;

  String? _lastDHash;

  Future<void> waitForFrameBudget() async {
    await SchedulerBinding.instance.endOfFrame;
  }

  Future<ScreenshotCaptureResult?> capture({
    String? lastDHash,
    bool force = false,
    bool waitForFrame = true,
  }) async {
    final sw = Stopwatch()..start();
    if (waitForFrame) await waitForFrameBudget();

    final context = boundaryKey.currentContext;
    if (context == null || !context.mounted) return null;

    final boundary = context.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.isRepaintBoundary) {
      return null;
    }

    final rootRender = boundary;
    if (!rootRender.hasSize) return null;

    final maskRects = _collectMaskRects(context as Element, rootRender);

    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final scaledWidth = image.width;
      final scaledHeight = image.height;
      ui.Image rasterImage = image;

      if (maskRects.isNotEmpty) {
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
        rasterImage = await picture.toImage(scaledWidth, scaledHeight);
        picture.dispose();
      }

      try {
        final rasterMicros = sw.elapsedMicroseconds;
        final quickDHash = await _dHashFromThumbnail(rasterImage);
        final compareDHash = lastDHash ?? _lastDHash;
        if (!force &&
            compareDHash != null &&
            compareDHash.isNotEmpty &&
            quickDHash == compareDHash) {
          sw.stop();
          return ScreenshotCaptureResult(
            bytes: Uint8List(0),
            contentHash: '',
            dHash: quickDHash,
            width: scaledWidth,
            height: scaledHeight,
            masked: maskRects.isNotEmpty,
            captureMicros: rasterMicros,
            encodeMicros: 0,
            skippedByDHash: true,
          );
        }

        final encodeStart = sw.elapsedMicroseconds;
        final byteData = await rasterImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (byteData == null) return null;
        final png = byteData.buffer.asUint8List();
        final contentHash = sha256.convert(png).toString();
        final encodeMicros = sw.elapsedMicroseconds - encodeStart;
        _lastDHash = quickDHash;
        sw.stop();
        return ScreenshotCaptureResult(
          bytes: png,
          contentHash: contentHash,
          dHash: quickDHash,
          width: scaledWidth,
          height: scaledHeight,
          masked: maskRects.isNotEmpty,
          captureMicros: rasterMicros,
          encodeMicros: encodeMicros,
        );
      } finally {
        if (!identical(rasterImage, image)) {
          rasterImage.dispose();
        }
      }
    } finally {
      image.dispose();
    }
  }

  Future<String> _dHashFromThumbnail(ui.Image source) async {
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
    final thumb = await picture.toImage(hashWidth, hashHeight);
    picture.dispose();
    try {
      final bytes = await thumb.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return '';
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
    };
  }
}
