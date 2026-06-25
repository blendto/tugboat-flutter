import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'controller.dart';

class InputCapture {
  InputCapture({required this.controller, required this.rootKey});

  final PmkitReplayController controller;
  final GlobalKey rootKey;

  bool _installed = false;
  DateTime? _lastScrollSample;
  RenderObject? _activeScrollable;

  void install() {
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  void dispose() {
    if (!_installed) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _installed = false;
  }

  void _onPointer(PointerEvent event) {
    if (!controller.recording) return;

    if (event is PointerDownEvent) {
      controller.recordPointerDown(event.position, pointer: event.pointer);
    } else if (event is PointerUpEvent) {
      controller.recordPointerUp(event.position, pointer: event.pointer);
    } else if (event is PointerMoveEvent && controller.scrolling) {
      _maybeRecordScrollSample(event.position);
    }
  }

  void onScrollStart(Offset? position) {
    _activeScrollable = position == null ? null : _scrollableAt(position);
    _lastScrollSample = null;
    controller.onScrollActivityChanged(active: true);
    final offset = _scrollOffsetFor(_activeScrollable);
    if (offset != null) {
      controller.recordScrollSample(offset);
    }
  }

  void onScrollEnd(Offset? position) {
    final scrollable =
        _activeScrollable ??
        (position == null ? null : _scrollableAt(position));
    final offset = _scrollOffsetFor(scrollable);
    if (offset != null) {
      controller.recordScrollSample(offset);
    }
    _activeScrollable = null;
    controller.onScrollActivityChanged(active: false);
  }

  void _maybeRecordScrollSample(Offset position) {
    final now = DateTime.now();
    if (_lastScrollSample != null &&
        now.difference(_lastScrollSample!) <
            controller.config.scrollCaptureInterval) {
      return;
    }
    _lastScrollSample = now;
    final scrollable = _activeScrollable ?? _scrollableAt(position);
    final offset = _scrollOffsetFor(scrollable);
    if (offset == null) return;
    controller.recordScrollSample(offset);
  }

  RenderObject? _scrollableAt(Offset globalPosition) {
    final rootRender = rootKey.currentContext?.findRenderObject();
    if (rootRender is! RenderBox) return null;
    final result = BoxHitTestResult();
    rootRender.hitTest(result, position: globalPosition);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderAbstractViewport) return target;
      if (target is RenderViewport) return target;
    }
    return null;
  }

  double? _scrollOffsetFor(RenderObject? renderObject) {
    if (renderObject is RenderViewport) {
      return renderObject.offset.pixels;
    }
    return null;
  }
}
