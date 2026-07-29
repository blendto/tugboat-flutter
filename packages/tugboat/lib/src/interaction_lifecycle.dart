import 'dart:async';

import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'interaction_transaction.dart';
import 'models.dart';
import 'replay_config.dart';

typedef InteractionDelayScheduler =
    ({Future<void> done, void Function() cancel}) Function(Duration duration);

/// Host callbacks the lifecycle needs without owning capture/route state.
class InteractionLifecycleHost {
  const InteractionLifecycleHost({
    required this.atMs,
    required this.config,
    required this.sessionId,
    required this.isDisposed,
    required this.addEvent,
    required this.nextEventId,
    required this.scheduleDelay,
    required this.promoteLegacyTapInSession,
  });

  final int Function() atMs;
  final TugboatReplayConfig Function() config;
  final String? Function() sessionId;
  final bool Function() isDisposed;
  final void Function(TugboatEvent event) addEvent;
  final String Function() nextEventId;
  final InteractionDelayScheduler scheduleDelay;

  /// Patches in-memory session tap / tap_outside_tree peers for causal promotion.
  final void Function(String tapEventId, Map<String, Object?> promotion)
  promoteLegacyTapInSession;
}

/// Owns transaction registry, claim, reconciliation, and publish policy.
class InteractionLifecycle {
  InteractionLifecycle(this._host);

  final InteractionLifecycleHost _host;
  final InteractionRegistry registry = InteractionRegistry();

  bool _sweepScheduled = false;
  void Function()? _sweepCancel;

  int get _atMs => _host.atMs();
  TugboatReplayConfig get _config => _host.config();

  void beginPointerDown({
    required int pointer,
    required InteractionTransaction tx,
  }) {
    final previous = registry.removeReleased(pointer);
    if (previous != null) {
      previous.cancelled = true;
      previous.sameTurnEligible = false;
      previous.rejectionReason ??= InteractionRejectionReason.claimConsumed;
      // Settle still owns terminal publish for a released tap that already
      // emitted; only drop unresolved cause ids here.
      if (!previous.tapEmitted) {
        registry.forgetId(previous.id);
      }
    }
    if (registry.pendingAt(pointer) != null) {
      abandonPending(pointer, gestureFinal: 'superseded');
    }
    registry.register(tx);
  }

  /// Publish a legacy peer through the single stream policy gate.
  void emitLegacy(TugboatEvent event) {
    if (!_config.emitLegacyInteractionProjection) return;
    _host.addEvent(event.copyWith(stream: _config.legacyGestureStream));
  }

  void emitBufferedTap(
    InteractionTransaction tx, {
    required String gestureFinal,
    required String replayRole,
  }) {
    if (tx.tapEmitted) return;
    tx.tapEmitted = true;
    final emittedAtMs = _atMs;
    final outside = tx.bufferedOutside;
    if (outside != null) {
      emitLegacy(
        outside.copyWith(
          atMs: emittedAtMs,
          data: {
            ...outside.data,
            'gestureFinal': gestureFinal,
            'replayRole': replayRole,
            'sampledAtMs': outside.atMs,
          },
        ),
      );
      tx.bufferedOutside = null;
    }
    final tap = tx.bufferedTap;
    if (tap != null) {
      emitLegacy(
        tap.copyWith(
          atMs: emittedAtMs,
          data: {
            ...tap.data,
            'gestureFinal': gestureFinal,
            'replayRole': replayRole,
            'sampledAtMs': tap.atMs,
          },
        ),
      );
      tx.bufferedTap = null;
    }
    // Cause resolution uses the retained InteractionTransaction object or the
    // causeEventId string on route_change; id index is not required after emit.
    registry.forgetId(tx.id);
  }

  void ensureCauseTapPublished(String? causeEventId) {
    if (causeEventId == null) return;
    final tx = registry.byId(causeEventId);
    if (tx == null || tx.tapEmitted) return;
    emitBufferedTap(tx, gestureFinal: 'unresolved', replayRole: 'causal_only');
  }

  void promoteCausalTap(String tapEventId) {
    if (!_config.emitLegacyInteractionProjection) return;
    const promotion = <String, Object?>{
      'gestureFinal': 'tap',
      'replayRole': 'interaction',
      'promotedFrom': 'causal_only',
    };
    _host.promoteLegacyTapInSession(tapEventId, promotion);
    emitLegacy(
      TugboatEvent(
        id: _host.nextEventId(),
        atMs: _atMs,
        type: 'tap_gesture_resolved',
        relatedEventId: tapEventId,
        data: {
          'gestureFinal': 'tap',
          'replayRole': 'interaction',
          'promotesRelatedTap': true,
          'interactionId': tapEventId,
        },
      ),
    );
  }

  void releaseForReconciliation(InteractionTransaction tx) {
    final pointer = tx.pointerId;
    tx.sameTurnEligible = true;
    tx.releasedAtMs = _atMs;
    registry.release(tx);
    final window = _config.interactionClaimWindow;
    if (window <= Duration.zero) {
      scheduleMicrotask(() {
        if (!identical(registry.byPointer(pointer), tx)) return;
        tx.sameTurnEligible = false;
        registry.removeReleased(pointer);
        if (!tx.claimed && !tx.tapEmitted) {
          tx.rejectionReason ??= InteractionRejectionReason.expired;
          registry.forgetId(tx.id);
        }
      });
      return;
    }
    tx.reconciliationDeadlineMs = _atMs + window.inMilliseconds;
    _ensureSweepScheduled();
  }

  void _ensureSweepScheduled() {
    if (_sweepScheduled) return;
    if (!registry.hasReleased) return;
    final earliest = registry.earliestReleasedDeadlineMs();
    if (earliest == null) return;
    final delayMs = earliest - _atMs;
    final delay = Duration(milliseconds: delayMs < 0 ? 0 : delayMs);
    _sweepScheduled = true;
    final scheduled = _host.scheduleDelay(delay);
    _sweepCancel = scheduled.cancel;
    unawaited(
      scheduled.done.then((_) {
        _sweepScheduled = false;
        _sweepCancel = null;
        if (_host.isDisposed()) return;
        _sweepReleased();
        if (registry.hasReleased) _ensureSweepScheduled();
      }),
    );
  }

  void _sweepReleased() {
    final now = _atMs;
    final expired = <InteractionTransaction>[];
    for (final tx in registry.released) {
      final deadline = tx.reconciliationDeadlineMs;
      if (deadline == null) continue;
      if (now < deadline) continue;
      expired.add(tx);
    }
    for (final tx in expired) {
      _expireReleased(tx);
    }
    while (registry.releasedCount > tugboatMaxReleasedInteractionTransactions) {
      final oldest = registry.oldestReleased();
      if (oldest == null) break;
      _expireReleased(oldest);
    }
  }

  void _expireReleased(InteractionTransaction tx) {
    tx.sameTurnEligible = false;
    if (!tx.claimed && !tx.cancelled) {
      tx.rejectionReason ??= InteractionRejectionReason.expired;
    }
    registry.removeReleased(tx.pointerId);
    if (!tx.claimed && !tx.tapEmitted) {
      registry.forgetId(tx.id);
    }
  }

  void dropBuffers(InteractionTransaction tx) {
    tx.cancelled = true;
    tx.bufferedTap = null;
    tx.bufferedOutside = null;
    if (!tx.claimed) registry.forgetId(tx.id);
  }

  /// Single terminal path for abandoned / cancelled / superseded gestures.
  void terminate(
    InteractionTransaction tx, {
    required InteractionRejectionReason reason,
    String gestureFinal = 'cancelled',
    bool publishClaimedTap = true,
  }) {
    if (tx.isPublished) return;
    if (tx.claimed && !tx.tapEmitted && publishClaimedTap) {
      emitBufferedTap(
        tx,
        gestureFinal: gestureFinal,
        replayRole: 'causal_only',
      );
    } else if (!tx.tapEmitted) {
      dropBuffers(tx);
    }
    tx.cancelled = true;
    tx.rejectionReason ??= reason;
    tx.attribution = InteractionAttribution.none;
    if (!tx.isSwipeOrScroll) {
      tx.gesture = InteractionGesture.cancelled;
    }
    tx.resultStatus = InteractionResultStatus.cancelled;
    tx.resultObservedAtMs ??= _atMs;
    publishCanonical(tx);
  }

  void abandonPending(
    int pointer, {
    required String gestureFinal,
    bool publishClaimedTap = true,
  }) {
    final pending = registry.removePending(pointer);
    if (pending == null) return;
    final reason = switch (gestureFinal) {
      'superseded' => InteractionRejectionReason.claimConsumed,
      'session_end' => InteractionRejectionReason.sessionEnd,
      _ => InteractionRejectionReason.lifecycle,
    };
    terminate(
      pending,
      reason: reason,
      gestureFinal: gestureFinal,
      publishClaimedTap: publishClaimedTap,
    );
  }

  void abandonAllPending({
    bool publishClaimedTap = true,
    String gestureFinal = 'session_end',
  }) {
    for (final tx in registry.takeAllPending()) {
      final reason = switch (gestureFinal) {
        'superseded' => InteractionRejectionReason.claimConsumed,
        'session_end' => InteractionRejectionReason.sessionEnd,
        _ => InteractionRejectionReason.lifecycle,
      };
      terminate(
        tx,
        reason: reason,
        gestureFinal: gestureFinal,
        publishClaimedTap: publishClaimedTap,
      );
    }
  }

  /// Terminalize every open transaction against the *current* session.
  void reset({
    InteractionRejectionReason reason = InteractionRejectionReason.sessionEnd,
    bool publishClaimedTap = false,
  }) {
    _sweepCancel?.call();
    _sweepCancel = null;
    _sweepScheduled = false;
    abandonAllPending(
      publishClaimedTap: publishClaimedTap,
      gestureFinal: reason == InteractionRejectionReason.sessionEnd
          ? 'session_end'
          : 'lifecycle',
    );
    for (final tx in registry.takeAllReleased()) {
      terminate(tx, reason: reason, publishClaimedTap: publishClaimedTap);
      if (!tx.tapEmitted) {
        dropBuffers(tx);
        registry.forgetId(tx.id);
      }
    }
  }

  void clearWithoutPublish() {
    _sweepCancel?.call();
    _sweepCancel = null;
    _sweepScheduled = false;
    registry.clearAll();
  }

  void cancelPointer(int pointer) {
    final pending = registry.removePending(pointer);
    if (pending != null) {
      terminate(
        pending,
        reason: InteractionRejectionReason.lifecycle,
        gestureFinal: 'cancelled',
      );
    }
    final released = registry.removeReleased(pointer);
    if (released != null) {
      terminate(
        released,
        reason: InteractionRejectionReason.lifecycle,
        gestureFinal: 'cancelled',
      );
    }
  }

  void markSwipe(int pointer) {
    final pending = registry.pendingAt(pointer);
    if (pending == null) return;
    pending.markSwipe();
    if (!pending.claimed) {
      pending.rejectionReason ??=
          InteractionRejectionReason.gestureReclassified;
      dropBuffers(pending);
    }
  }

  void linkScrollStart(String scrollStartEventId) {
    for (final tx in registry.pending) {
      if (!tx.scrollStartEventIds.contains(scrollStartEventId)) {
        tx.scrollStartEventIds.add(scrollStartEventId);
      }
      tx.addEvidence(scrollStartEventId);
    }
  }

  void publishCanonical(InteractionTransaction tx) {
    if (tx.isPublished) return;
    tx.phase = InteractionPhase.published;
    if (!_config.emitCanonicalInteractions) return;
    _host.addEvent(
      TugboatEvent(
        id: _host.nextEventId(),
        atMs: _atMs,
        type: 'interaction',
        stateAnchor: tx.origin.stateAnchor,
        targetAnchor: tx.origin.targetAnchor,
        beforeFrame: tx.origin.beforeFrame,
        afterFrame: tx.afterFrame,
        result:
            tx.resultStatus?.asEventResult ?? TugboatInteractionResult.unknown,
        data: {
          'interactionId': tx.id,
          'interactionSchema': tugboatInteractionSchemaVersion,
          'gesture': tx.gesture.name,
          'origin': tx.origin.toJson(),
          'result': tx.resultToJson(),
          'attribution': tx.attributionToJson(
            windowMs: _config.interactionClaimWindow.inMilliseconds,
          ),
          'evidenceEventIds': List<String>.from(tx.evidenceEventIds),
        },
      ),
    );
  }

  InteractionTransaction? tryClaim({String? navigatorId}) {
    final eligible = registry.eligibleForClaim(
      nowMs: _atMs,
      sessionId: _host.sessionId(),
    );
    if (eligible.length != 1) {
      if (eligible.length > 1) {
        for (final tx in eligible) {
          tx.rejectionReason ??= InteractionRejectionReason.competingPointer;
        }
      }
      return null;
    }
    final tx = eligible.single;
    if (navigatorId != null &&
        tx.origin.navigatorId != null &&
        tx.origin.navigatorId != navigatorId) {
      tx.rejectionReason ??= InteractionRejectionReason.navigatorMismatch;
      return null;
    }
    tx.claimed = true;
    final windowActive = _config.interactionClaimWindow > Duration.zero;
    final isPending = registry.pendingAt(tx.pointerId) != null;
    tx.attribution = (isPending || !windowActive)
        ? InteractionAttribution.direct
        : InteractionAttribution.delayedLikely;
    return tx;
  }

  void dispose() {
    _sweepCancel?.call();
    _sweepCancel = null;
    _sweepScheduled = false;
    registry.clearAll();
  }
}

/// Builds buffered legacy tap peers for a new transaction (stream applied at emit).
void attachBufferedTapPeers({
  required InteractionTransaction tx,
  required Offset position,
  required int pointer,
  required TugboatStateAnchor? beforeState,
  required String? beforeFrame,
  required Map<String, Object?> tapData,
  required String Function() nextEventId,
}) {
  final startedAtMs = tx.origin.atMs;
  final eventId = tx.id;
  tx.bufferedOutside = tx.origin.targetAnchor == null
      ? TugboatEvent(
          id: nextEventId(),
          atMs: startedAtMs,
          type: 'tap_outside_tree',
          stateAnchor: beforeState,
          beforeFrame: beforeFrame,
          data: {
            'x': position.dx,
            'y': position.dy,
            'pointer': pointer,
            'interactionId': eventId,
          },
        )
      : null;
  tx.bufferedTap = TugboatEvent(
    id: eventId,
    atMs: startedAtMs,
    type: 'tap',
    stateAnchor: beforeState,
    targetAnchor: tx.origin.targetAnchor,
    beforeFrame: beforeFrame,
    data: {...tapData, 'interactionId': eventId},
  );
}
