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
    required this.stateAnchor,
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
  final TugboatStateAnchor? stateAnchor;
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

  Map<String, Object?> toJson() => {
    'interactionId': interactionId,
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
    if (explorationRunId != null) 'explorationRunId': explorationRunId,
    if (actionId != null) 'actionId': actionId,
  };
}

enum InteractionGesture { tap, swipe, scroll, cancelled }

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

  final List<String> evidenceEventIds = <String>[];
  final List<String> scrollStartEventIds = <String>[];

  InteractionResultStatus? resultStatus;
  InteractionAttribution attribution = InteractionAttribution.none;
  InteractionRejectionReason? rejectionReason;
  String? resultRoute;
  String? resultRouteInstanceId;
  String? afterFrame;
  String? captureOutcome;
  int? resultObservedAtMs;
  TugboatStateAnchor? resultStateAnchor;

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
    if (afterFrame != null) 'afterFrame': afterFrame,
    if (captureOutcome != null) 'captureOutcome': captureOutcome,
    if (resultObservedAtMs != null) 'observedAtMs': resultObservedAtMs,
  };

  Map<String, Object?> attributionToJson({int? windowMs}) => {
    'kind': attribution.wireName,
    if (windowMs != null) 'windowMs': windowMs,
    if (rejectionReason != null) 'rejectionReason': rejectionReason!.name,
  };
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
