import 'dart:async';
import 'dart:collection';

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
    required this.stateAnchor,
    required this.route,
    required this.routeInstanceId,
    required this.navigatorId,
    required this.targetAnchor,
    required this.captureCoordinate,
    required this.beforeFrame,
    required this.atMs,
    required this.startPosition,
    required this.pointerGeneration,
    required this.captureSessionId,
  });

  final String interactionId;
  final TugboatStateAnchor? stateAnchor;
  final String? route;
  final String? routeInstanceId;
  final String? navigatorId;
  final TugboatTargetAnchor? targetAnchor;
  final TugboatCaptureCoordinate captureCoordinate;
  final String? beforeFrame;
  final int atMs;
  final Offset startPosition;
  final int pointerGeneration;
  final String? captureSessionId;

  Map<String, Object?> toJson() => {
    'interactionId': interactionId,
    if (stateAnchor != null) 'stateAnchor': stateAnchor!.toJson(),
    if (route != null) 'route': route,
    if (routeInstanceId != null) 'routeInstanceId': routeInstanceId,
    if (navigatorId != null) 'navigatorId': navigatorId,
    if (targetAnchor != null) 'targetAnchor': targetAnchor!.toJson(),
    'captureCoordinate': captureCoordinate.toJson(),
    if (beforeFrame != null) 'beforeFrame': beforeFrame,
    'atMs': atMs,
    'startPosition': {'x': startPosition.dx, 'y': startPosition.dy},
    'pointerGeneration': pointerGeneration,
    if (captureSessionId != null) 'captureSessionId': captureSessionId,
  };
}

enum InteractionGesture { tap, swipe, scroll, cancelled }

/// Wire `interaction.result.status` vocabulary.
///
/// Maps onto [TugboatInteractionResult] only at event emission; cancelled has
/// no event-level peer and becomes [TugboatInteractionResult.unknown].
enum InteractionResultStatus {
  navigated,
  changed,
  unchanged,
  unknown,
  cancelled;

  TugboatInteractionResult get asEventResult => switch (this) {
    InteractionResultStatus.navigated => TugboatInteractionResult.navigated,
    InteractionResultStatus.changed => TugboatInteractionResult.changed,
    InteractionResultStatus.unchanged =>
      TugboatInteractionResult.noVisibleChange,
    InteractionResultStatus.cancelled ||
    InteractionResultStatus.unknown => TugboatInteractionResult.unknown,
  };

  static InteractionResultStatus fromSettle({
    required TugboatInteractionResult result,
    String navigationOutcome = 'same_route',
    bool degraded = false,
  }) {
    if (degraded) return InteractionResultStatus.unknown;
    if (navigationOutcome == 'navigated') {
      return InteractionResultStatus.navigated;
    }
    return switch (result) {
      TugboatInteractionResult.navigated => InteractionResultStatus.navigated,
      TugboatInteractionResult.changed => InteractionResultStatus.changed,
      TugboatInteractionResult.noVisibleChange =>
        InteractionResultStatus.unchanged,
      TugboatInteractionResult.unknown => InteractionResultStatus.unknown,
    };
  }
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

  /// Route_change compatibility string when a claim succeeds.
  ///
  /// Returns null for [none] — callers must not write attribution on
  /// unclaimed routes.
  String? get claimWireName => switch (this) {
    InteractionAttribution.direct => 'same_turn',
    InteractionAttribution.delayedLikely => 'delayed_likely',
    InteractionAttribution.none => null,
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

/// Lifecycle phase for one gesture transaction.
enum InteractionPhase {
  /// Pointer is down; buffers held, not yet released.
  pending,

  /// Pointer up; eligible for delayed route/modal claim.
  released,

  /// Terminal — canonical interaction published (or intentionally suppressed).
  published,
}

/// Bounded in-memory transaction for one pointer gesture.
class InteractionTransaction {
  InteractionTransaction({required this.origin, required this.pointerId});

  final InteractionOrigin origin;
  final int pointerId;

  InteractionPhase phase = InteractionPhase.pending;
  InteractionGesture gesture = InteractionGesture.tap;
  bool claimed = false;
  bool cancelled = false;
  bool tapEmitted = false;
  bool sameTurnEligible = true;

  int? releasedAtMs;
  int? reconciliationDeadlineMs;

  TugboatEvent? bufferedTap;
  TugboatEvent? bufferedOutside;

  final List<String> evidenceEventIds = <String>[];
  final List<String> scrollStartEventIds = <String>[];

  InteractionResultStatus? resultStatus;
  InteractionAttribution attribution = InteractionAttribution.none;
  InteractionRejectionReason? rejectionReason;
  String? resultRoute;
  String? resultRouteInstanceId;
  String? afterFrame;
  int? resultObservedAtMs;
  TugboatStateAnchor? resultStateAnchor;

  Completer<void>? _successorSignal;

  String get id => origin.interactionId;

  bool get isSwipeOrScroll =>
      gesture == InteractionGesture.swipe ||
      gesture == InteractionGesture.scroll;

  bool get isPublished => phase == InteractionPhase.published;

  bool get isEligible =>
      !claimed && !cancelled && !isPublished && !isSwipeOrScroll;

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

  void addEvidence(String eventId) {
    if (!evidenceEventIds.contains(eventId)) evidenceEventIds.add(eventId);
  }

  void markSwipe() {
    gesture = InteractionGesture.swipe;
  }

  Map<String, Object?> resultToJson() => {
    'status': (resultStatus ?? InteractionResultStatus.unknown).name,
    if (resultRoute != null) 'route': resultRoute,
    if (resultRouteInstanceId != null) 'routeInstanceId': resultRouteInstanceId,
    if (resultStateAnchor != null) 'stateAnchor': resultStateAnchor!.toJson(),
    if (afterFrame != null) 'afterFrame': afterFrame,
    if (resultObservedAtMs != null) 'observedAtMs': resultObservedAtMs,
  };

  Map<String, Object?> attributionToJson({int? windowMs}) => {
    'kind': attribution.wireName,
    if (windowMs != null) 'windowMs': windowMs,
    if (rejectionReason != null) 'rejectionReason': rejectionReason!.name,
  };
}

/// Index for pending/released interaction transactions.
///
/// Primary key is interaction id. Pointer maps are secondary indexes; released
/// order is an explicit FIFO queue for eviction.
class InteractionRegistry {
  final Map<String, InteractionTransaction> _byId = {};
  final Map<int, InteractionTransaction> _pendingByPointer = {};
  final Map<int, InteractionTransaction> _releasedByPointer = {};
  final ListQueue<InteractionTransaction> _releasedOrder =
      ListQueue<InteractionTransaction>();

  Iterable<InteractionTransaction> get pending => _pendingByPointer.values;
  Iterable<InteractionTransaction> get released =>
      List<InteractionTransaction>.unmodifiable(_releasedOrder);
  bool get hasPending => _pendingByPointer.isNotEmpty;
  bool get hasReleased => _releasedOrder.isNotEmpty;
  int get releasedCount => _releasedOrder.length;

  InteractionTransaction? byPointer(int pointer) =>
      _pendingByPointer[pointer] ?? _releasedByPointer[pointer];

  InteractionTransaction? pendingAt(int pointer) => _pendingByPointer[pointer];

  InteractionTransaction? byId(String id) => _byId[id];

  void register(InteractionTransaction tx) {
    _byId[tx.id] = tx;
    _pendingByPointer[tx.pointerId] = tx;
  }

  InteractionTransaction? removePending(int pointer) {
    final tx = _pendingByPointer.remove(pointer);
    return tx;
  }

  void release(InteractionTransaction tx) {
    _pendingByPointer.remove(tx.pointerId);
    final previous = _releasedByPointer[tx.pointerId];
    if (previous != null && !identical(previous, tx)) {
      _releasedOrder.remove(previous);
    }
    _releasedByPointer[tx.pointerId] = tx;
    if (!_releasedOrder.contains(tx)) {
      _releasedOrder.addLast(tx);
    }
    tx.phase = InteractionPhase.released;
  }

  InteractionTransaction? removeReleased(int pointer) {
    final tx = _releasedByPointer.remove(pointer);
    if (tx != null) _releasedOrder.remove(tx);
    return tx;
  }

  /// Drop id lookup when the cause id no longer needs to resolve.
  void forgetId(String id) => _byId.remove(id);

  void clearAll() {
    _pendingByPointer.clear();
    _releasedByPointer.clear();
    _releasedOrder.clear();
    _byId.clear();
  }

  List<InteractionTransaction> takeAllReleased() {
    final values = List<InteractionTransaction>.from(_releasedOrder);
    _releasedByPointer.clear();
    _releasedOrder.clear();
    return values;
  }

  List<int> takePendingPointers() => List<int>.from(_pendingByPointer.keys);

  List<InteractionTransaction> takeAllPending() {
    final values = List<InteractionTransaction>.from(_pendingByPointer.values);
    _pendingByPointer.clear();
    return values;
  }

  InteractionTransaction? oldestReleased() =>
      _releasedOrder.isEmpty ? null : _releasedOrder.first;

  List<InteractionTransaction> eligibleForClaim({
    required int nowMs,
    required String? sessionId,
  }) {
    final eligible = <InteractionTransaction>[];
    for (final tx in _pendingByPointer.values) {
      if (!tx.isEligible) continue;
      if (tx.origin.captureSessionId != sessionId) continue;
      eligible.add(tx);
    }
    for (final tx in _releasedOrder) {
      if (!tx.isEligible) continue;
      if (!tx.isWithinReconciliationWindow(nowMs)) continue;
      if (tx.origin.captureSessionId != sessionId) continue;
      eligible.add(tx);
    }
    return eligible;
  }

  int? earliestReleasedDeadlineMs() {
    int? earliest;
    for (final tx in _releasedOrder) {
      final deadline = tx.reconciliationDeadlineMs;
      if (deadline == null) continue;
      if (earliest == null || deadline < earliest) earliest = deadline;
    }
    return earliest;
  }
}
