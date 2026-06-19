import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'markers.dart';
import 'perceptual_hash.dart';
import 'screenshot_encode.dart';
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
    this.pixelRatio = 0.75,
  });

  final GlobalKey boundaryKey;
  final double pixelRatio;
  final TugboatScreenshotMaskLevel maskLevel;

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
        final byteData = await rasterImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (byteData == null) return null;
        final rgba = byteData.buffer.asUint8List();
        final rasterMicros = sw.elapsedMicroseconds;

        final quickDHash = computeDHashFromRgba(
          rgba,
          scaledWidth,
          scaledHeight,
        );
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

        final encoded = await encodeScreenshotOffThread(
          RawScreenshotData(
            rgba: rgba,
            width: scaledWidth,
            height: scaledHeight,
            masked: maskRects.isNotEmpty,
          ),
        );
        _lastDHash = encoded.dHash;
        sw.stop();
        return ScreenshotCaptureResult(
          bytes: encoded.bytes,
          contentHash: encoded.contentHash,
          dHash: encoded.dHash,
          width: scaledWidth,
          height: scaledHeight,
          masked: maskRects.isNotEmpty,
          captureMicros: rasterMicros,
          encodeMicros: encoded.encodeMicros,
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

  List<MaskRect> _collectMaskRects(Element root, RenderBox ancestor) {
    final masks = <MaskRect>[];
    final maskedRenderObjects = <RenderObject>{};

    void visit(Element element, bool sensitive, bool actionable) {
      final widget = element.widget;
      final renderObject = element.renderObject;
      if (_hidesSubtree(widget, renderObject) || widget is TugboatInternal) {
        return;
      }

      final isSensitive = sensitive || widget is TugboatSensitive;
      final isActionable = actionable || _isActionable(widget);

      if (renderObject is RenderBox &&
          renderObject.attached &&
          renderObject.hasSize &&
          _shouldMask(widget, renderObject, isSensitive, isActionable) &&
          maskedRenderObjects.add(renderObject)) {
        try {
          final transformed = MatrixUtils.transformRect(
            renderObject.getTransformTo(ancestor),
            renderObject.paintBounds,
          );
          final rect = transformed.intersect(ancestor.paintBounds);
          if (rect.width > 0 && rect.height > 0) {
            masks.add(MaskRect(rect));
          }
        } catch (_) {
          // A detached render object can race capture; omit its mask safely.
        }
      }

      element.visitChildElements(
        (child) => visit(child, isSensitive, isActionable),
      );
    }

    root.visitChildElements((child) => visit(child, false, false));
    return masks;
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
        widget is EditableText && _isSensitiveInput(widget);

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

  bool _isSensitiveInput(EditableText widget) {
    return widget.obscureText ||
        widget.keyboardType == TextInputType.emailAddress ||
        widget.keyboardType == TextInputType.phone ||
        widget.keyboardType == TextInputType.visiblePassword;
  }

  bool _isActionable(Widget widget) {
    if (widget is ButtonStyleButton) return widget.onPressed != null;
    if (widget is IconButton) return widget.onPressed != null;
    if (widget is MaterialButton) return widget.onPressed != null;
    if (widget is FloatingActionButton) return widget.onPressed != null;
    if (widget is CupertinoButton) return widget.onPressed != null;
    if (widget is InkWell || widget is InkResponse) {
      return switch (widget) {
        InkWell w => w.onTap != null,
        InkResponse w => w.onTap != null,
        _ => false,
      };
    }
    if (widget is GestureDetector) {
      return widget.onTap != null ||
          widget.onDoubleTap != null ||
          widget.onLongPress != null;
    }
    if (widget is ListTile) {
      return widget.enabled &&
          (widget.onTap != null || widget.onLongPress != null);
    }
    if (widget is EditableText ||
        widget is TextField ||
        widget is TextFormField) {
      return true;
    }
    return false;
  }

  bool _hidesSubtree(Widget widget, RenderObject? renderObject) {
    if (widget is Offstage) return widget.offstage;
    if (widget is Visibility) return !widget.visible;
    if (widget is Opacity) return widget.opacity == 0;
    if (renderObject is RenderOffstage) return renderObject.offstage;
    if (renderObject is RenderOpacity) return renderObject.opacity == 0;
    if (renderObject is RenderAnimatedOpacity) {
      return renderObject.opacity.value == 0;
    }
    return false;
  }
}
