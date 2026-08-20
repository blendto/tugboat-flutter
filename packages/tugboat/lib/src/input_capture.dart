import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'controller.dart';
import 'interaction_transaction.dart';

/// Minimum trackpad scale ratio treated as zoom rather than pan.
const double tugboatTrackpadZoomRatio = 1.08;

/// Classifies a two-pointer touch cluster as pan, zoom-in, or zoom-out.
///
/// Zoom wins when the span change exceeds [kScaleSlop]. Otherwise a centroid
/// shift of [kPanSlop] is pan. Returns null when the motion is still within
/// slop of the cluster origin.
InteractionGesture? classifyPointerScaleGesture({
  required double startSpan,
  required double currentSpan,
  required Offset startCentroid,
  required Offset currentCentroid,
}) {
  if (startSpan >= kTouchSlop) {
    final spanDelta = (currentSpan - startSpan).abs();
    if (spanDelta >= kScaleSlop) {
      return currentSpan > startSpan
          ? InteractionGesture.zoomIn
          : InteractionGesture.zoomOut;
    }
  }
  if ((currentCentroid - startCentroid).distance >= kPanSlop) {
    return InteractionGesture.pan;
  }
  return null;
}

/// Classifies a trackpad [PointerPanZoomUpdateEvent] as pan or zoom.
InteractionGesture? classifyTrackpadPanZoom({
  required double scale,
  required Offset pan,
}) {
  if (scale >= tugboatTrackpadZoomRatio) {
    return InteractionGesture.zoomIn;
  }
  if (scale > 0 && scale <= 1 / tugboatTrackpadZoomRatio) {
    return InteractionGesture.zoomOut;
  }
  if (pan.distance >= kPanSlop) {
    return InteractionGesture.pan;
  }
  return null;
}

/// Last known primary-pointer point, even when a secondary pointer lifts first.
Offset primaryPointerEndPosition({
  required int primaryPointer,
  required Map<int, Offset> pointerPositions,
  required Offset fallback,
}) {
  return pointerPositions[primaryPointer] ?? fallback;
}

class InputCapture {
  InputCapture({required this.controller, required this.rootKey});

  final TugboatReplayController controller;
  final GlobalKey rootKey;

  bool _installed = false;
  final Map<int, Offset> _pointerDownPositions = {};
  final Map<int, Offset> _pointerPositions = {};
  final List<int> _pointerOrder = [];
  final Map<int, bool> _pointerIsSwipe = {};
  _MultiPointerSession? _multi;
  int? _panZoomPointer;
  InteractionGesture? _panZoomClassified;

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

  void handlePointerDown(PointerDownEvent event) {
    _pointerDownPositions[event.pointer] = event.position;
    _pointerPositions[event.pointer] = event.position;
    _pointerOrder.add(event.pointer);
    _pointerIsSwipe[event.pointer] = false;
    controller.recordPointerDown(event.position, pointer: event.pointer);
    if (_pointerPositions.length >= 2) {
      _ensureMultiPointerSession();
    }
  }

  void handlePointerMove(PointerMoveEvent event) {
    _pointerPositions[event.pointer] = event.position;
    final multi = _multi;
    if (multi != null && multi.pointers.contains(event.pointer)) {
      _classifyMultiPointer();
      return;
    }
    _maybeClassifySwipe(event);
  }

  void handlePointerUp(PointerUpEvent event) {
    _pointerPositions[event.pointer] = event.position;
    final multi = _multi;
    if (multi != null && multi.pointers.contains(event.pointer)) {
      if (multi.classified != null) {
        final endPosition = primaryPointerEndPosition(
          primaryPointer: multi.primaryPointer,
          pointerPositions: _pointerPositions,
          fallback: event.position,
        );
        _completeMultiPointer(endPosition);
        return;
      }
      _multi = null;
    }
    controller.recordPointerUp(event.position, pointer: event.pointer);
    _clearPointer(event.pointer);
  }

  void handlePointerCancel(PointerCancelEvent event) {
    final multi = _multi;
    if (multi != null && multi.pointers.contains(event.pointer)) {
      final pointers = Set<int>.from(multi.pointers);
      controller.recordPointerCancel(
        event.position,
        pointer: multi.primaryPointer,
      );
      for (final pointer in pointers) {
        if (pointer != multi.primaryPointer) {
          controller.suppressPendingPointer(pointer);
        }
      }
      _multi = null;
      _clearPointers(pointers);
      return;
    }
    if (_panZoomPointer == event.pointer) {
      _clearPanZoom();
    }
    controller.recordPointerCancel(event.position, pointer: event.pointer);
    _clearPointer(event.pointer);
  }

  void handlePanZoomStart(PointerPanZoomStartEvent event) {
    _panZoomPointer = event.pointer;
    _panZoomClassified = null;
    controller.recordPointerDown(event.position, pointer: event.pointer);
  }

  void handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final classified = classifyTrackpadPanZoom(
      scale: event.scale,
      pan: event.pan,
    );
    if (classified == null) return;
    _panZoomClassified = classified;
    controller.markPendingScaleGesture(
      pointer: event.pointer,
      gesture: classified,
      scale: event.scale,
      pointerCount: 2,
    );
  }

  void handlePanZoomEnd(PointerPanZoomEndEvent event) {
    if (_panZoomClassified == null) {
      controller.recordPointerCancel(event.position, pointer: event.pointer);
    } else {
      controller.recordPointerUp(event.position, pointer: event.pointer);
    }
    _clearPanZoom();
    _clearPointer(event.pointer);
  }

  void _onPointer(PointerEvent event) {
    if (!controller.recording) return;

    if (event is PointerDownEvent) {
      handlePointerDown(event);
    } else if (event is PointerUpEvent) {
      handlePointerUp(event);
    } else if (event is PointerCancelEvent) {
      handlePointerCancel(event);
    } else if (event is PointerMoveEvent) {
      handlePointerMove(event);
    } else if (event is PointerPanZoomStartEvent) {
      handlePanZoomStart(event);
    } else if (event is PointerPanZoomUpdateEvent) {
      handlePanZoomUpdate(event);
    } else if (event is PointerPanZoomEndEvent) {
      handlePanZoomEnd(event);
    }
  }

  void _maybeClassifySwipe(PointerMoveEvent event) {
    if (_pointerIsSwipe[event.pointer] == true) return;
    final down = _pointerDownPositions[event.pointer];
    if (down == null) return;
    final delta = event.position - down;
    if (delta.distance >= kTouchSlop) {
      _pointerIsSwipe[event.pointer] = true;
      controller.markPendingTapAsSwipe(event.pointer);
    }
  }

  void _ensureMultiPointerSession() {
    if (_multi != null) return;
    if (_pointerOrder.length < 2) return;
    final primary = _pointerOrder[0];
    final secondary = _pointerOrder[1];
    final first = _pointerPositions[primary];
    final second = _pointerPositions[secondary];
    if (first == null || second == null) return;
    _multi = _MultiPointerSession(
      primaryPointer: primary,
      pointers: {primary, secondary},
      startCentroid: _centroidOf([first, second]),
      startSpan: (first - second).distance,
    );
  }

  void _classifyMultiPointer() {
    final multi = _multi;
    if (multi == null) return;
    final points = <Offset>[];
    for (final pointer in multi.pointers) {
      final point = _pointerPositions[pointer];
      if (point == null) return;
      points.add(point);
    }
    if (points.length < 2) return;
    final centroid = _centroidOf(points);
    final span = (points[0] - points[1]).distance;
    final classified = classifyPointerScaleGesture(
      startSpan: multi.startSpan,
      currentSpan: span,
      startCentroid: multi.startCentroid,
      currentCentroid: centroid,
    );
    if (classified == null) return;
    multi.classified = classified;
    multi.scale = multi.startSpan > 0 ? span / multi.startSpan : 1;
    controller.markPendingScaleGesture(
      pointer: multi.primaryPointer,
      gesture: classified,
      scale: multi.scale,
      pointerCount: multi.pointers.length,
    );
    for (final pointer in multi.pointers) {
      if (pointer != multi.primaryPointer) {
        controller.suppressPendingPointer(pointer);
      }
    }
  }

  void _completeMultiPointer(Offset endPosition) {
    final multi = _multi;
    if (multi == null || multi.classified == null) return;
    controller.markPendingScaleGesture(
      pointer: multi.primaryPointer,
      gesture: multi.classified!,
      scale: multi.scale,
      pointerCount: multi.pointers.length,
    );
    for (final pointer in multi.pointers) {
      if (pointer != multi.primaryPointer) {
        controller.suppressPendingPointer(pointer);
      }
    }
    controller.recordPointerUp(endPosition, pointer: multi.primaryPointer);
    final pointers = Set<int>.from(multi.pointers);
    _multi = null;
    _clearPointers(pointers);
  }

  void _clearPanZoom() {
    _panZoomPointer = null;
    _panZoomClassified = null;
  }

  void _clearPointer(int pointer) {
    _pointerDownPositions.remove(pointer);
    _pointerPositions.remove(pointer);
    _pointerOrder.remove(pointer);
    _pointerIsSwipe.remove(pointer);
  }

  void _clearPointers(Iterable<int> pointers) {
    for (final pointer in pointers) {
      _clearPointer(pointer);
    }
  }
}

class _MultiPointerSession {
  _MultiPointerSession({
    required this.primaryPointer,
    required this.pointers,
    required this.startCentroid,
    required this.startSpan,
  });

  final int primaryPointer;
  final Set<int> pointers;
  final Offset startCentroid;
  final double startSpan;
  InteractionGesture? classified;
  double scale = 1;
}

Offset _centroidOf(List<Offset> points) {
  var x = 0.0;
  var y = 0.0;
  for (final point in points) {
    x += point.dx;
    y += point.dy;
  }
  return Offset(x / points.length, y / points.length);
}
