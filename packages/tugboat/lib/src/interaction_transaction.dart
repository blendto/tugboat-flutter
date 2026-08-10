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

enum InteractionGesture { tap, swipe, scroll, cancelled }

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

/// Facts-only interaction schema v2 fields stored in [TugboatEvent.data].
Map<String, Object?> buildInteractionV2Payload(InteractionTransaction tx) {
  final payload = <String, Object?>{
    'interactionSchema': tugboatInteractionSchemaVersion,
    'gesture': tx.gesture.name,
  };
  final route = tx.origin.route;
  if (route != null && route.isNotEmpty) {
    payload['route'] = route;
  }
  final fingerprint = tx.origin.targetAnchor?.fingerprint;
  if (fingerprint != null && fingerprint.isNotEmpty) {
    payload['targetFingerprint'] = fingerprint;
  }
  final coord = tx.origin.captureCoordinate;
  if (coord.isAvailable &&
      coord.normalizedX >= 0 &&
      coord.normalizedX <= 1 &&
      coord.normalizedY >= 0 &&
      coord.normalizedY <= 1) {
    payload['position'] = {
      'xNorm': coord.normalizedX,
      'yNorm': coord.normalizedY,
    };
  }
  return payload;
}

/// Bounded in-memory transaction for one pointer gesture.
class InteractionTransaction {
  InteractionTransaction({required this.origin, required this.pointerId});

  final InteractionOrigin origin;
  final int pointerId;

  InteractionGesture gesture = InteractionGesture.tap;
  bool claimed = false;
  bool cancelled = false;
  bool tapEmitted = false;
  bool semanticPublished = false;
  bool sameTurnEligible = true;

  int? releasedAtMs;
  int? reconciliationDeadlineMs;

  TugboatEvent? bufferedTap;
  TugboatEvent? bufferedOutside;

  final List<String> scrollStartEventIds = <String>[];

  InteractionAttribution attribution = InteractionAttribution.none;
  InteractionRejectionReason? rejectionReason;
  String? afterFrame;

  Completer<void>? _successorSignal;

  String get id => origin.interactionId;

  bool get isSwipeOrScroll =>
      gesture == InteractionGesture.swipe ||
      gesture == InteractionGesture.scroll;

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
    gesture = InteractionGesture.swipe;
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
      if (tx.isSwipeOrScroll) continue;
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
