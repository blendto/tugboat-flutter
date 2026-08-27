import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'controller.dart';
import 'interaction_transaction.dart';

/// Minimum trackpad scale ratio treated as zoom rather than pan.
const double tugboatTrackpadZoomRatio = 1.08;

/// Classifies a multi-pointer touch cluster as pan, zoom-in, zoom-out, or swipe.
///
/// For two pointers, zoom wins when span change exceeds [kScaleSlop], otherwise
/// shared translation is pan. For three or more pointers, shared translation
/// past [kPanSlop] is swipe. Zoom still wins when span change exceeds slop.
InteractionGesture? classifyMultiPointerGesture({
  required int pointerCount,
  required double startSpan,
  required double currentSpan,
  required Offset startCentroid,
  required Offset currentCentroid,
}) {
  if (pointerCount >= 2 && startSpan > 0) {
    final spanDelta = (currentSpan - startSpan).abs();
    if (spanDelta >= kScaleSlop) {
      return currentSpan > startSpan
          ? InteractionGesture.zoomIn
          : InteractionGesture.zoomOut;
    }
  }
  if ((currentCentroid - startCentroid).distance >= kPanSlop) {
    if (pointerCount >= 3) {
      return InteractionGesture.swipe;
    }
    return InteractionGesture.pan;
  }
  return null;
}

/// Classifies a two-pointer touch cluster as pan, zoom-in, or zoom-out.
///
/// Prefer [classifyMultiPointerGesture] for clusters that may grow past two
/// pointers.
InteractionGesture? classifyPointerScaleGesture({
  required double startSpan,
  required double currentSpan,
  required Offset startCentroid,
  required Offset currentCentroid,
}) {
  return classifyMultiPointerGesture(
    pointerCount: 2,
    startSpan: startSpan,
    currentSpan: currentSpan,
    startCentroid: startCentroid,
    currentCentroid: currentCentroid,
  );
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
  Offset? _panZoomEndPosition;

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
      if (_multi != null) {
        _growMultiPointerSession(event.pointer);
      } else {
        _ensureMultiPointerSession();
      }
    }
  }

  void handlePointerMove(PointerMoveEvent event) {
    if (!_pointerDownPositions.containsKey(event.pointer)) return;
    _pointerPositions[event.pointer] = event.position;
    final multi = _multi;
    if (multi != null && multi.pointers.contains(event.pointer)) {
      if (event.pointer == multi.primaryPointer) {
        multi.primaryEndPosition = event.position;
      }
      _classifyMultiPointer();
      return;
    }
    _maybeClassifySwipe(event);
  }

  void handlePointerUp(PointerUpEvent event) {
    if (!_pointerDownPositions.containsKey(event.pointer)) return;
    final previousPosition = _pointerPositions[event.pointer];
    _pointerPositions[event.pointer] = event.position;
    final multi = _multi;
    if (multi != null && multi.pointers.contains(event.pointer)) {
      if (event.pointer == multi.primaryPointer) {
        multi.primaryEndPosition = event.position;
      }
      if (previousPosition != event.position) {
        _classifyMultiPointer();
      }
      if (multi.classified != null) {
        multi.pointers.remove(event.pointer);
        _clearPointer(event.pointer);
        if (multi.pointers.isEmpty) {
          _completeMultiPointer(multi.primaryEndPosition);
        } else {
          // Keep the transaction until every contact lifts. A replacement
          // finger must join this gesture, not start a separate swipe.
          _refreshMultiPointerBaseline(multi);
        }
        return;
      }
      _multi = null;
    }
    controller.recordPointerUp(event.position, pointer: event.pointer);
    _clearPointer(event.pointer);
    _ensureMultiPointerSession();
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
    _panZoomEndPosition = event.position;
    controller.recordPointerDown(event.position, pointer: event.pointer);
  }

  void handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_panZoomPointer != event.pointer) return;
    _panZoomEndPosition = event.position + event.pan;
    final classified = classifyTrackpadPanZoom(
      scale: event.scale,
      pan: event.pan,
    );
    if (classified == null) return;
    _panZoomClassified = classified;
    controller.markPendingClusterGesture(
      pointer: event.pointer,
      gesture: classified,
      scale: event.scale,
      pointerCount: 2,
    );
  }

  void handlePanZoomEnd(PointerPanZoomEndEvent event) {
    if (_panZoomPointer != event.pointer) return;
    if (_panZoomClassified == null) {
      controller.recordPointerCancel(event.position, pointer: event.pointer);
    } else {
      controller.recordPointerUp(
        _panZoomEndPosition ?? event.position,
        pointer: event.pointer,
      );
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
    final pointers = _pointerOrder.toSet();
    final points = <Offset>[];
    for (final pointer in _pointerOrder) {
      final point = _pointerPositions[pointer];
      if (point == null) return;
      points.add(point);
    }
    if (points.length < 2) return;
    _multi = _MultiPointerSession(
      primaryPointer: _pointerOrder.first,
      primaryEndPosition: points.first,
      pointers: pointers,
      startCentroid: _centroidOf(points),
      startSpan: _maxSpan(points),
    );
  }

  void _growMultiPointerSession(int pointer) {
    final multi = _multi;
    if (multi == null || !multi.pointers.add(pointer)) return;
    if (multi.classified != null) {
      controller.suppressPendingPointer(pointer);
    }
    _refreshMultiPointerBaseline(multi);
  }

  void _refreshMultiPointerBaseline(_MultiPointerSession multi) {
    // A contact change alters the span without scaling the content. Preserve
    // the scale so later movement continues from the last classified segment.
    multi.baseScale = multi.scale;
    final points = <Offset>[];
    for (final activePointer in multi.pointers) {
      final point = _pointerPositions[activePointer];
      if (point == null) return;
      points.add(point);
    }
    if (points.length < 2) return;
    multi.startCentroid = _centroidOf(points);
    multi.startSpan = _maxSpan(points);
    if (multi.classified == null) {
      multi.initialSpan = multi.startSpan;
    }
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
    final span = _maxSpan(points);
    final scale = multi.startSpan > 0
        ? multi.baseScale * span / multi.startSpan
        : 1.0;
    final classified = classifyMultiPointerGesture(
      pointerCount: multi.pointers.length,
      startSpan: multi.initialSpan,
      currentSpan: multi.initialSpan * scale,
      startCentroid: multi.startCentroid,
      currentCentroid: centroid,
    );
    if (classified == null) return;
    multi.classified = classified;
    multi.classifiedPointerCount = multi.pointers.length;
    multi.scale = scale;
    _applyClusterClassification(multi);
  }

  void _applyClusterClassification(_MultiPointerSession multi) {
    final classified = multi.classified;
    if (classified == null) return;
    controller.markPendingClusterGesture(
      pointer: multi.primaryPointer,
      gesture: classified,
      scale: multi.scale,
      pointerCount: multi.classifiedPointerCount,
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
    _applyClusterClassification(multi);
    controller.recordPointerUp(endPosition, pointer: multi.primaryPointer);
    final pointers = Set<int>.from(multi.pointers);
    _multi = null;
    _clearPointers(pointers);
  }

  void _clearPanZoom() {
    _panZoomPointer = null;
    _panZoomClassified = null;
    _panZoomEndPosition = null;
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
    required this.primaryEndPosition,
    required Set<int> pointers,
    required this.startCentroid,
    required this.startSpan,
  }) : pointers = Set<int>.from(pointers),
       initialSpan = startSpan;

  final int primaryPointer;
  final Set<int> pointers;
  double initialSpan;
  Offset primaryEndPosition;
  Offset startCentroid;
  double startSpan;
  InteractionGesture? classified;
  int classifiedPointerCount = 1;
  double scale = 1;
  double baseScale = 1;
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

double _maxSpan(List<Offset> points) {
  var maxSpan = 0.0;
  for (var i = 0; i < points.length; i++) {
    for (var j = i + 1; j < points.length; j++) {
      final span = (points[i] - points[j]).distance;
      if (span > maxSpan) maxSpan = span;
    }
  }
  return maxSpan;
}
