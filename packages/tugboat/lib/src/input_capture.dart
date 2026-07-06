import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'controller.dart';

class InputCapture {
  InputCapture({required this.controller, required this.rootKey});

  final TugboatReplayController controller;
  final GlobalKey rootKey;

  bool _installed = false;
  final Map<int, Offset> _pointerDownPositions = {};
  final Map<int, bool> _pointerIsSwipe = {};

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
    _pointerIsSwipe[event.pointer] = false;
    controller.recordPointerDown(event.position, pointer: event.pointer);
  }

  void handlePointerMove(PointerMoveEvent event) {
    _maybeClassifySwipe(event);
  }

  void handlePointerUp(PointerUpEvent event) {
    controller.recordPointerUp(event.position, pointer: event.pointer);
    _clearPointer(event.pointer);
  }

  void handlePointerCancel(PointerCancelEvent event) {
    controller.recordPointerCancel(event.position, pointer: event.pointer);
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

  void _clearPointer(int pointer) {
    _pointerDownPositions.remove(pointer);
    _pointerIsSwipe.remove(pointer);
  }
}
