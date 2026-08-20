import 'dart:async';

import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'coordinate_space.dart';
import 'models.dart';

/// Default post-pointer-up window for delayed causal route/modal attribution.
const Duration tugboatDefaultReconciliationWindow = Duration(
  milliseconds: 1250,
);

/// Maximum released transactions retained for delayed reconciliation.
const int tugboatMaxReleasedInteractionTransactions = 8;

/// Immutable pointer-down origin for one user gesture.
class InteractionOrigin {
  const InteractionOrigin({
    required this.interactionId,
    required this.route,
    required this.routeEpoch,
    required this.routeInstanceId,
    required this.navigatorId,
    required this.targetAnchor,
    required this.captureCoordinate,
    required this.beforeFrame,
    required this.atMs,
    required this.startPosition,
    required this.pointerGeneration,
    required this.captureSessionId,
    this.explorationRunId,
    this.actionId,
  });

  final String interactionId;
  final String? route;
  final int routeEpoch;
  final String? routeInstanceId;
  final String? navigatorId;
  final TugboatTargetAnchor? targetAnchor;
  final TugboatCaptureCoordinate captureCoordinate;
  final String? beforeFrame;
  final int atMs;
  final Offset startPosition;
  final int pointerGeneration;
  final String? captureSessionId;
  final String? explorationRunId;
  final String? actionId;
}

enum InteractionGesture {
  tap,
  swipe,
  scroll,
  pan,
  zoomIn,
  zoomOut,
  cancelled;

  String get wireName => switch (this) {
    InteractionGesture.tap => 'tap',
    InteractionGesture.swipe => 'swipe',
    InteractionGesture.scroll => 'scroll',
    InteractionGesture.pan => 'pan',
    InteractionGesture.zoomIn => 'zoom_in',
    InteractionGesture.zoomOut => 'zoom_out',
    InteractionGesture.cancelled => 'cancelled',
  };
}

enum InteractionAttribution {
  direct,
  delayedLikely,
  none;

  String get wireName => switch (this) {
    InteractionAttribution.direct => 'direct',
    InteractionAttribution.delayedLikely => 'delayed_likely',
    InteractionAttribution.none => 'none',
  };

  /// Route_change compatibility string (`same_turn` | `delayed_likely`).
  String get claimWireName => switch (this) {
    InteractionAttribution.direct => 'same_turn',
    InteractionAttribution.delayedLikely => 'delayed_likely',
    InteractionAttribution.none => 'same_turn',
  };
}

enum InteractionRejectionReason {
  expired,
  competingPointer,
  gestureReclassified,
  navigatorMismatch,
  automaticGuard,
  claimConsumed,
  lifecycle,
  sessionEnd,
}

Map<String, double>? interactionNormalizedPosition(
  TugboatCaptureCoordinate coordinate,
) {
  if (!coordinate.isAvailable) return null;
  if (coordinate.normalizedX < 0 ||
      coordinate.normalizedX > 1 ||
      coordinate.normalizedY < 0 ||
      coordinate.normalizedY > 1) {
    return null;
  }
  return {'xNorm': coordinate.normalizedX, 'yNorm': coordinate.normalizedY};
}

Map<String, double>? interactionNormalizedPoint(
  Offset global,
  TugboatCaptureCoordinate reference,
) {
  if (!reference.isAvailable ||
      reference.boundaryWidth <= 0 ||
      reference.boundaryHeight <= 0) {
    return null;
  }
  final localX = global.dx - reference.boundaryOriginX;
  final localY = global.dy - reference.boundaryOriginY;
  return {
    'xNorm': (localX / reference.boundaryWidth).clamp(0.0, 1.0),
    'yNorm': (localY / reference.boundaryHeight).clamp(0.0, 1.0),
  };
}

/// Facts-only interaction schema v2 fields stored in [TugboatEvent.data].
Map<String, Object?> buildInteractionV2Payload(InteractionTransaction tx) {
  final envelope = <String, Object?>{
    'interactionSchema': tugboatInteractionSchemaVersion,
    'gesture': tx.gesture.wireName,
  };
  final route = tx.origin.route;
  if (route != null && route.isNotEmpty) {
    envelope['route'] = route;
  }
  final fingerprint = tx.gesture == InteractionGesture.scroll
      ? (tx.scrollTargetAnchor?.fingerprint ?? tx.targetAnchor?.fingerprint)
      : tx.targetAnchor?.fingerprint;
  if (fingerprint != null && fingerprint.isNotEmpty) {
    envelope['targetFingerprint'] = fingerprint;
  }
  if (tx.gesture == InteractionGesture.cancelled) {
    return envelope;
  }

  final gesturePayload = <String, Object?>{};
  final position = interactionNormalizedPosition(tx.origin.captureCoordinate);
  if (position != null) {
    gesturePayload['position'] = position;
  }

  switch (tx.gesture) {
    case InteractionGesture.tap:
      break;
    case InteractionGesture.swipe:
    case InteractionGesture.pan:
    case InteractionGesture.zoomIn:
    case InteractionGesture.zoomOut:
      _writeTravelGesturePayload(gesturePayload, tx, position);
      break;
    case InteractionGesture.scroll:
      _writeScrollGesturePayload(gesturePayload, tx);
      break;
    case InteractionGesture.cancelled:
      break;
  }

  if (gesturePayload.isNotEmpty) {
    envelope['payload'] = gesturePayload;
  }
  return envelope;
}

void _writeTravelGesturePayload(
  Map<String, Object?> gesturePayload,
  InteractionTransaction tx,
  Map<String, double>? position,
) {
  final endPosition = tx.endPosition;
  if (endPosition != null) {
    final end = interactionNormalizedPoint(
      endPosition,
      tx.origin.captureCoordinate,
    );
    if (end != null) {
      gesturePayload['endPosition'] = end;
      if (position != null) {
        gesturePayload['delta'] = {
          'xNorm': end['xNorm']! - position['xNorm']!,
          'yNorm': end['yNorm']! - position['yNorm']!,
        };
      }
    }
  }
  if (tx.gesture != InteractionGesture.swipe && tx.pointerCount > 1) {
    gesturePayload['pointerCount'] = tx.pointerCount;
  }
  if (tx.gesture == InteractionGesture.zoomIn ||
      tx.gesture == InteractionGesture.zoomOut) {
    final scale = tx.scale;
    if (scale != null) {
      gesturePayload['scale'] = scale;
    }
  }
}

void _writeScrollGesturePayload(
  Map<String, Object?> gesturePayload,
  InteractionTransaction tx,
) {
  if (tx.scrollStartOffset != null) {
    gesturePayload['startOffset'] = tx.scrollStartOffset;
  }
  if (tx.scrollEndOffset != null) {
    gesturePayload['endOffset'] = tx.scrollEndOffset;
  }
  if (tx.overscrollCount > 0) {
    gesturePayload['overscrollCount'] = tx.overscrollCount;
  }
}

/// Bounded in-memory transaction for one pointer gesture.
class InteractionTransaction {
  InteractionTransaction({required this.origin, required this.pointerId})
    : targetAnchor = origin.targetAnchor;

  final InteractionOrigin origin;
  final int pointerId;

  InteractionGesture gesture = InteractionGesture.tap;
  bool claimed = false;
  bool cancelled = false;
  bool semanticPublished = false;
  bool sameTurnEligible = true;

  int? releasedAtMs;
  int? releasedFrameSequence;
  int? reconciliationDeadlineMs;

  final List<String> scrollStartEventIds = <String>[];

  InteractionAttribution attribution = InteractionAttribution.none;
  InteractionRejectionReason? rejectionReason;
  String? afterFrame;
  Offset? endPosition;
  double? scrollStartOffset;
  double? scrollEndOffset;
  int overscrollCount = 0;
  TugboatTargetAnchor? scrollTargetAnchor;
  double? scale;
  int pointerCount = 1;

  /// Resolved only after this gesture remains a tap. Pointer-down stores only
  /// origin facts so possible scrolls do not pay tap inventory costs.
  TugboatTargetAnchor? targetAnchor;

  Completer<void>? _successorSignal;

  String get id => origin.interactionId;

  bool get isSwipeOrScroll =>
      gesture == InteractionGesture.swipe ||
      gesture == InteractionGesture.scroll;

  bool get isPanOrZoom =>
      gesture == InteractionGesture.pan ||
      gesture == InteractionGesture.zoomIn ||
      gesture == InteractionGesture.zoomOut;

  bool get skipsTapSettlement => isSwipeOrScroll || isPanOrZoom;

  bool get isEligible => !claimed && !cancelled && !semanticPublished;

  bool isWithinReconciliationWindow(int nowMs) {
    if (!sameTurnEligible) return false;
    final deadline = reconciliationDeadlineMs;
    if (deadline == null) return sameTurnEligible;
    return nowMs <= deadline;
  }

  void signalSuccessorClaimed() {
    final signal = _successorSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  Future<void> awaitSuccessorOrDeadline(Future<void> deadline) {
    final signal = Completer<void>();
    _successorSignal = signal;
    return Future.any<void>([deadline, signal.future]).whenComplete(() {
      if (identical(_successorSignal, signal)) _successorSignal = null;
    });
  }

  void markSwipe() {
    if (isPanOrZoom) return;
    gesture = InteractionGesture.swipe;
  }

  void markScale({
    required InteractionGesture gesture,
    required double scale,
    required int pointerCount,
  }) {
    if (gesture != InteractionGesture.pan &&
        gesture != InteractionGesture.zoomIn &&
        gesture != InteractionGesture.zoomOut) {
      return;
    }
    this.gesture = gesture;
    this.scale = scale;
    this.pointerCount = pointerCount;
  }
}

/// Single index for pending/released interaction transactions.
class InteractionRegistry {
  final Map<int, InteractionTransaction> _pending = {};
  final Map<int, InteractionTransaction> _released = {};
  final Map<String, InteractionTransaction> _byId = {};

  Iterable<InteractionTransaction> get pending => _pending.values;
  Iterable<InteractionTransaction> get released => _released.values;
  bool get hasPending => _pending.isNotEmpty;
  bool get hasReleased => _released.isNotEmpty;
  int get releasedCount => _released.length;

  InteractionTransaction? byPointer(int pointer) =>
      _pending[pointer] ?? _released[pointer];

  InteractionTransaction? pendingAt(int pointer) => _pending[pointer];

  InteractionTransaction? byId(String id) => _byId[id];

  void register(InteractionTransaction tx) {
    _byId[tx.id] = tx;
    _pending[tx.pointerId] = tx;
  }

  InteractionTransaction? removePending(int pointer) =>
      _pending.remove(pointer);

  void release(InteractionTransaction tx) {
    _pending.remove(tx.pointerId);
    _released[tx.pointerId] = tx;
  }

  InteractionTransaction? removeReleased(int pointer) =>
      _released.remove(pointer);

  void forgetId(String id) => _byId.remove(id);

  void clearAll() {
    _pending.clear();
    _released.clear();
    _byId.clear();
  }

  List<InteractionTransaction> takeAllReleased() {
    final values = List<InteractionTransaction>.from(_released.values);
    _released.clear();
    return values;
  }

  List<int> takePendingPointers() => List<int>.from(_pending.keys);

  List<InteractionTransaction> eligibleForClaim({
    required int nowMs,
    required String? sessionId,
  }) {
    final eligible = <InteractionTransaction>[];
    for (final tx in _pending.values) {
      if (tx.skipsTapSettlement) continue;
      if (!tx.isEligible) continue;
      if (tx.origin.captureSessionId != sessionId) continue;
      eligible.add(tx);
    }
    for (final tx in _released.values) {
      if (!tx.isEligible) continue;
      if (!tx.isWithinReconciliationWindow(nowMs)) continue;
      if (tx.origin.captureSessionId != sessionId) continue;
      eligible.add(tx);
    }
    return eligible;
  }

  int? earliestReleasedDeadlineMs() {
    int? earliest;
    for (final tx in _released.values) {
      final deadline = tx.reconciliationDeadlineMs;
      if (deadline == null) continue;
      if (earliest == null || deadline < earliest) earliest = deadline;
    }
    return earliest;
  }
}
