import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/controller.dart';
import 'package:tugboat/tugboat.dart';

/// Controllable clock + delay queue for deterministic controller tests.
///
/// Delays scheduled through [TugboatReplayController.debugDelay] are parked
/// until [advance] reaches their due time. Tests never sleep on the wall clock.
class ControllableScheduler {
  ControllableScheduler({DateTime? epoch})
    : _elapsed = Duration.zero,
      _epoch = epoch ?? DateTime.utc(2026, 1, 1);

  final DateTime _epoch;
  Duration _elapsed;
  final List<_ScheduledDelay> _delays = <_ScheduledDelay>[];

  DateTime now() => _epoch.add(_elapsed);

  Duration get elapsed => _elapsed;

  Future<void> delay(Duration duration) {
    if (duration <= Duration.zero) {
      // Mirror Future.delayed(Duration.zero): yield a turn to the event loop.
      final completer = Completer<void>();
      scheduleMicrotask(completer.complete);
      return completer.future;
    }
    final completer = Completer<void>();
    _delays.add(
      _ScheduledDelay(due: _elapsed + duration, completer: completer),
    );
    _delays.sort((a, b) => a.due.compareTo(b.due));
    return completer.future;
  }

  /// Advances virtual time and completes every delay that is now due.
  void advance(Duration step) {
    if (step < Duration.zero) {
      throw ArgumentError.value(step, 'step', 'must be non-negative');
    }
    _elapsed += step;
    while (_delays.isNotEmpty && _delays.first.due <= _elapsed) {
      final next = _delays.removeAt(0);
      if (!next.completer.isCompleted) {
        next.completer.complete();
      }
    }
  }

  /// Completes every pending delay immediately by jumping to the latest due time.
  void flush() {
    if (_delays.isEmpty) return;
    final latest = _delays.last.due;
    if (latest > _elapsed) {
      advance(latest - _elapsed);
    }
  }

  int get pendingDelayCount => _delays.length;

  bool get hasPendingDelays => _delays.isNotEmpty;
}

class _ScheduledDelay {
  _ScheduledDelay({required this.due, required this.completer});

  final Duration due;
  final Completer<void> completer;
}

/// Controllable capture executor that plants synthetic frames on demand.
class ControllableCaptureExecutor {
  ControllableCaptureExecutor(this.controller);

  final TugboatReplayController controller;
  final List<TugboatFrameTrigger> triggers = <TugboatFrameTrigger>[];
  final List<Completer<String?>> _blocked = <Completer<String?>>[];

  bool failNext = false;
  bool blockNext = false;
  String? Function(TugboatFrameTrigger trigger, bool force)? frameFactory;

  Future<String?> call({
    required TugboatFrameTrigger trigger,
    required bool force,
  }) async {
    triggers.add(trigger);
    if (failNext) {
      failNext = false;
      throw StateError('simulated capture failure');
    }
    if (blockNext) {
      blockNext = false;
      final completer = Completer<String?>();
      _blocked.add(completer);
      return completer.future;
    }
    final custom = frameFactory?.call(trigger, force);
    if (custom != null) return custom;
    return controller.debugSeedFrame(
      contentHash:
          'capture-${trigger.name}-${controller.session!.frames.length}',
      trigger: trigger,
    );
  }

  int get blockedCount => _blocked.length;

  void completeBlocked([String? frameId]) {
    for (final completer in List<Completer<String?>>.from(_blocked)) {
      if (!completer.isCompleted) {
        completer.complete(
          frameId ??
              controller.debugSeedFrame(
                contentHash: 'unblocked-${controller.session!.frames.length}',
              ),
        );
      }
    }
    _blocked.clear();
  }
}

/// Wired controller + scheduler + capture executor for coherence characterization.
///
/// Uses plain async tests (not FakeAsync/`testWidgets`) so capture and queue
/// futures progress under an explicitly advanceable [scheduler].
class ReplayCoherenceHarness {
  ReplayCoherenceHarness({
    this.settleDelay = Duration.zero,
    GlobalKey? boundaryKey,
  }) : boundaryKey = boundaryKey ?? GlobalKey();

  final Duration settleDelay;
  final GlobalKey boundaryKey;
  final ControllableScheduler scheduler = ControllableScheduler();

  late final TugboatReplayController controller;
  late final ControllableCaptureExecutor capturer;

  Future<void> setUp() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    controller = TugboatReplayController(
      config: TugboatReplayConfig(
        profile: TugboatCaptureProfile.exploration,
        settleDelay: settleDelay,
        enableGlobalPointerCapture: false,
        capturePixelRatio: 1.0,
      ),
      boundaryKey: boundaryKey,
    );
    capturer = ControllableCaptureExecutor(controller);
    controller.debugNow = scheduler.now;
    controller.debugDelay = scheduler.delay;
    controller.debugExecuteCapture = capturer.call;
    controller.debugFreezeStateAnchor = true;
    await controller.initialize();
    controller.start(const Size(390, 844), 'test');
    await pumpMicrotasks();
  }

  void dispose() {
    controller.dispose();
  }

  PageRoute<void> route(
    String name, {
    Duration transitionDuration = Duration.zero,
  }) {
    return PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      transitionDuration: transitionDuration,
      pageBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }

  String seedRouteState({
    required String route,
    required String signature,
    String? frameContentHash,
  }) {
    controller.debugSetCurrentStateAnchor(
      TugboatStateAnchor(
        signature: signature,
        signatureParts: {'route': route},
      ),
    );
    return controller.debugSeedFrame(
      contentHash: frameContentHash ?? 'frame-$route',
      trigger: TugboatFrameTrigger.route,
    );
  }

  Future<void> pumpMicrotasks({int times = 8}) async {
    for (var i = 0; i < times; i++) {
      final gate = Completer<void>();
      scheduleMicrotask(gate.complete);
      await gate.future;
    }
  }

  /// Drains microtasks, then advances one scheduler quantum and drains again.
  Future<void> tick([Duration step = const Duration(milliseconds: 1)]) async {
    await pumpMicrotasks();
    if (step > Duration.zero) {
      scheduler.advance(step);
    }
    await pumpMicrotasks();
  }

  /// Runs queued work that is not blocked on a scheduler delay.
  Future<void> pumpQueueWork({int rounds = 20}) async {
    for (var i = 0; i < rounds; i++) {
      await pumpMicrotasks();
    }
  }

  Future<void> flushScheduler() async {
    await pumpMicrotasks();
    for (var i = 0; i < 100 && scheduler.hasPendingDelays; i++) {
      scheduler.advance(const Duration(milliseconds: 10));
      await pumpMicrotasks();
    }
    scheduler.flush();
    await pumpMicrotasks();
    await controller.drainPointerQueue();
    await pumpMicrotasks();
  }
}

/// Snapshot of coherence-relevant fields for one event.
class EventCoherenceView {
  const EventCoherenceView(this.event);

  final TugboatEvent event;

  String get type => event.type;
  String? get route => event.stateAnchor?.signatureParts['route'];
  String? get signature => event.stateAnchor?.signature;
  String? get beforeFrame => event.beforeFrame;
  String? get afterFrame => event.afterFrame;
  String? get relatedEventId => event.relatedEventId;
  TugboatInteractionResult? get result => event.result;
  String? get navigation => event.data['navigation'] as String?;
  String? get destinationRoute => event.data['route'] as String?;
  String? get fromRoute => event.data['fromRoute'] as String?;
}

extension SessionCoherence on TugboatSession {
  List<EventCoherenceView> coherenceEvents([Set<String>? types]) {
    final filter = types;
    return events
        .where((event) => filter == null || filter.contains(event.type))
        .map(EventCoherenceView.new)
        .toList();
  }

  List<TugboatEvent> ofType(String type) =>
      events.where((event) => event.type == type).toList();
}

/// Desired post-fix invariants. Characterization tests use these to prove
/// current production sequences violate coherence (the check returns false).
class CoherenceInvariants {
  /// Tap settle evidence belongs to one route epoch / frame family.
  static bool tapSettleIsRouteCoherent({
    required TugboatEvent tap,
    required TugboatEvent settle,
    required String? expectedRouteSignature,
  }) {
    if (settle.relatedEventId != tap.id) return false;
    if (settle.beforeFrame != tap.beforeFrame) return false;
    if (expectedRouteSignature != null &&
        settle.stateAnchor?.signature != expectedRouteSignature) {
      return false;
    }
    return true;
  }

  /// Destination-route actions must not reuse an origin-route frame id.
  static bool actionFrameMatchesRoute({
    required TugboatEvent action,
    required String? originFrameId,
    required String? destinationFrameId,
  }) {
    if (destinationFrameId == null) return false;
    if (action.beforeFrame == originFrameId &&
        originFrameId != destinationFrameId) {
      return false;
    }
    if (action.afterFrame == originFrameId &&
        originFrameId != destinationFrameId) {
      return false;
    }
    return true;
  }

  /// Navigation-producing taps must not emit an early unrelated noVisibleChange.
  static bool navigationTapHasNoEarlyNoVisibleChange({
    required List<TugboatEvent> events,
    required String tapEventId,
  }) {
    final settle = events.cast<TugboatEvent?>().firstWhere(
      (event) =>
          event?.type == 'tap_settled' && event?.relatedEventId == tapEventId,
      orElse: () => null,
    );
    if (settle == null) return false;
    final routeAfter = events.any(
      (event) => event.type == 'route_change' && event.atMs >= settle.atMs,
    );
    if (!routeAfter) return true;
    return settle.result != TugboatInteractionResult.noVisibleChange;
  }
}

/// Tiny opaque bytes used only when a real bytes map entry is required.
Uint8List emptyPngBytes() => Uint8List(0);
