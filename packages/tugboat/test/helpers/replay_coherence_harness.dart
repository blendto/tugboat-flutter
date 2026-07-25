import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

/// Key on the interactive target used by widget-backed harness modes.
const coherenceHarnessTargetKey = Key('coherence-harness-target');

/// Harness-only route provenance for a seeded or captured frame.
class HarnessFrameProvenance {
  const HarnessFrameProvenance({required this.route, required this.routeEpoch});

  final String route;
  final int routeEpoch;
}

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
  int _nextOrder = 0;
  final List<_ScheduledDelay> _delays = <_ScheduledDelay>[];

  DateTime now() => _epoch.add(_elapsed);

  Duration get elapsed => _elapsed;

  Future<void> delay(Duration duration) {
    return schedule(duration).done;
  }

  ({Future<void> done, void Function() cancel}) schedule(Duration duration) {
    if (duration <= Duration.zero) {
      // Mirror Future.delayed(Duration.zero): yield a turn to the event loop.
      final completer = Completer<void>();
      var cancelled = false;
      scheduleMicrotask(() {
        if (!cancelled && !completer.isCompleted) completer.complete();
      });
      return (
        done: completer.future,
        cancel: () {
          cancelled = true;
          if (!completer.isCompleted) completer.complete();
        },
      );
    }
    final completer = Completer<void>();
    final scheduled = _ScheduledDelay(
      due: _elapsed + duration,
      order: _nextOrder++,
      completer: completer,
    );
    _delays.add(scheduled);
    _delays.sort((a, b) {
      final dueOrder = a.due.compareTo(b.due);
      return dueOrder != 0 ? dueOrder : a.order.compareTo(b.order);
    });
    return (
      done: completer.future,
      cancel: () {
        _delays.remove(scheduled);
        if (!completer.isCompleted) completer.complete();
      },
    );
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
  _ScheduledDelay({
    required this.due,
    required this.order,
    required this.completer,
  });

  final Duration due;
  final int order;
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

  /// Harness-only cancellation/timeout seam for blocked captures. Production
  /// timeout/cancel behavior remains follow-up #10; tests use this to release
  /// waiters without calling [completeBlocked] manually.
  Duration? autoReleaseBlockedAfter;

  void Function(String frameId, {String? route, int? routeEpoch})?
  registerFrame;
  String? Function(TugboatFrameTrigger trigger, bool force)? frameFactory;

  void _trackFrame(String? frameId, {String? route, int? routeEpoch}) {
    if (frameId == null) return;
    registerFrame?.call(frameId, route: route, routeEpoch: routeEpoch);
  }

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
      _maybeScheduleAutoRelease(completer);
      return completer.future;
    }
    final custom = frameFactory?.call(trigger, force);
    if (custom != null) {
      _trackFrame(custom);
      return custom;
    }
    final frameId = controller.debugSeedFrame(
      contentHash:
          'capture-${trigger.name}-${controller.session!.frames.length}',
      trigger: trigger,
    );
    _trackFrame(frameId);
    return frameId;
  }

  int get blockedCount => _blocked.length;

  void completeBlocked([String? frameId]) {
    for (final completer in List<Completer<String?>>.from(_blocked)) {
      if (!completer.isCompleted) {
        final resolved =
            frameId ??
            controller.debugSeedFrame(
              contentHash: 'unblocked-${controller.session!.frames.length}',
            );
        _trackFrame(resolved);
        completer.complete(resolved);
      }
    }
    _blocked.clear();
  }

  void _maybeScheduleAutoRelease(Completer<String?> completer) {
    final releaseAfter = autoReleaseBlockedAfter;
    if (releaseAfter == null) return;
    autoReleaseBlockedAfter = null;
    final delay = controller.debugDelay;
    if (delay == null) return;
    unawaited(() async {
      await delay(releaseAfter);
      if (completer.isCompleted) return;
      completer.complete(null);
      _blocked.remove(completer);
    }());
  }
}

/// Wired controller + scheduler + capture executor for coherence characterization.
///
/// Uses plain async tests (not FakeAsync/`testWidgets`) so capture and queue
/// futures progress under an explicitly advanceable [scheduler].
class ReplayCoherenceHarness {
  ReplayCoherenceHarness({
    this.settleDelay = Duration.zero,
    this.maxFrames = 300,
    this.screenshotBudget = TugboatScreenshotBudgetConfig.defaults,
    GlobalKey? boundaryKey,
  }) : boundaryKey = boundaryKey ?? GlobalKey();

  final Duration settleDelay;
  final int maxFrames;
  final TugboatScreenshotBudgetConfig screenshotBudget;
  final GlobalKey boundaryKey;
  final ControllableScheduler scheduler = ControllableScheduler();
  final Map<String, HarnessFrameProvenance> _frameProvenance =
      <String, HarnessFrameProvenance>{};

  late final TugboatReplayController controller;
  late final ControllableCaptureExecutor capturer;

  HarnessFrameProvenance? provenanceFor(String? frameId) {
    if (frameId == null) return null;
    // Explicitly injected third-party evidence remains useful for invariant
    // negative tests; ordinary seeded/captured frames come from the controller.
    final injected = _frameProvenance[frameId];
    if (injected != null && injected.routeEpoch != controller.debugRouteEpoch) {
      return injected;
    }
    final provenance = controller.debugFrameProvenance(frameId);
    final route = provenance?['route'];
    final epoch = provenance?['routeEpoch'];
    if (route is String && epoch is int) {
      return HarnessFrameProvenance(route: route, routeEpoch: epoch);
    }
    return injected;
  }

  void registerFrameProvenance(
    String frameId, {
    required String route,
    int? routeEpoch,
  }) {
    _frameProvenance[frameId] = HarnessFrameProvenance(
      route: route,
      routeEpoch: routeEpoch ?? controller.debugRouteEpoch,
    );
  }

  Future<void> setUp() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    controller = TugboatReplayController(
      config: TugboatReplayConfig(
        profile: TugboatCaptureProfile.exploration,
        settleDelay: settleDelay,
        maxFrames: maxFrames,
        enableGlobalPointerCapture: false,
        capturePixelRatio: 1.0,
        screenshotBudget: screenshotBudget,
      ),
      boundaryKey: boundaryKey,
    );
    capturer = ControllableCaptureExecutor(controller);
    capturer.registerFrame = (frameId, {route, routeEpoch}) {
      final currentRoute = controller.currentRoute;
      final anchorRouteRaw =
          controller.currentStateAnchor?.signatureParts['route'];
      final anchorRoute = anchorRouteRaw is String && anchorRouteRaw.isNotEmpty
          ? anchorRouteRaw
          : null;
      final resolvedRoute =
          route ??
          (currentRoute != null && currentRoute.isNotEmpty
              ? currentRoute
              : null) ??
          (anchorRoute != null && anchorRoute.isNotEmpty
              ? anchorRoute
              : null) ??
          '';
      registerFrameProvenance(
        frameId,
        route: resolvedRoute,
        routeEpoch: routeEpoch,
      );
    };
    controller.debugNow = scheduler.now;
    controller.debugDelay = scheduler.delay;
    controller.debugScheduleDelay = scheduler.schedule;
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
    controller.debugSetCurrentRoute(route);
    controller.debugSetCurrentStateAnchor(
      TugboatStateAnchor(
        signature: signature,
        signatureParts: {'route': route},
      ),
    );
    final frameId = controller.debugSeedFrame(
      contentHash: frameContentHash ?? 'frame-$route',
      trigger: TugboatFrameTrigger.route,
    );
    registerFrameProvenance(frameId, route: route);
    return frameId;
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

  /// Mounts a minimal scene with a keyed interactive target under [boundaryKey].
  Future<void> mountWidgetBackedScene(WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: Scaffold(
            body: Center(
              child: FilledButton(
                key: coherenceHarnessTargetKey,
                onPressed: () {},
                child: const Text('Coherence target'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Initializes the harness after [mountWidgetBackedScene].
  Future<void> setUpWidgetBacked(WidgetTester tester) async {
    await mountWidgetBackedScene(tester);
    await setUp();
  }

  Offset targetTapPosition(WidgetTester tester) =>
      tester.getCenter(find.byKey(coherenceHarnessTargetKey));

  /// Simulates pointer-down → slop swipe classification → pointer-up without
  /// relying on [InputCapture], for deterministic characterization.
  Future<void> recordClassifiedSwipe(
    Offset start, {
    Offset? end,
    int pointer = 0,
  }) async {
    final finish = end ?? start.translate(0, -(kTouchSlop + 4));
    controller.recordPointerDown(start, pointer: pointer);
    controller.markPendingTapAsSwipe(pointer);
    controller.recordPointerUp(finish, pointer: pointer);
    await pumpMicrotasks();
  }

  Future<void> tearDownWidgetBacked(WidgetTester tester) async {
    dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
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
  /// Returns whether [events] are chronologically ordered and the requested
  /// [orderedEventIds] appear in that same order.
  ///
  /// This deliberately checks event time *and* session order: events can share
  /// a timestamp, but an emitted causal chain must never move backwards in the
  /// append-only replay journal.
  static bool hasChronologicalChain({
    required List<TugboatEvent> events,
    Iterable<String> orderedEventIds = const <String>[],
  }) {
    var previousAtMs = -1;
    final indexesById = <String, int>{};
    for (var index = 0; index < events.length; index++) {
      final event = events[index];
      if (event.atMs < previousAtMs) return false;
      previousAtMs = event.atMs;
      if (indexesById.putIfAbsent(event.id, () => index) != index) {
        return false;
      }
    }

    var previousIndex = -1;
    for (final id in orderedEventIds) {
      final index = indexesById[id];
      if (index == null || index <= previousIndex) return false;
      previousIndex = index;
    }
    return true;
  }

  /// Checks that every present frame on [event] belongs to one route epoch.
  static bool eventFramesMatchRoute({
    required TugboatEvent event,
    required String expectedRoute,
    required int expectedRouteEpoch,
    required HarnessFrameProvenance? Function(String? frameId)
    frameProvenanceFor,
    bool requireFrame = true,
  }) {
    final frameIds = <String>[
      if (event.beforeFrame != null) event.beforeFrame!,
      if (event.afterFrame != null) event.afterFrame!,
    ];
    if (requireFrame && frameIds.isEmpty) return false;
    return frameIds.every((frameId) {
      final provenance = frameProvenanceFor(frameId);
      return provenance?.route == expectedRoute &&
          provenance?.routeEpoch == expectedRouteEpoch;
    });
  }

  /// Checks the stable one-to-one relation between a tap and its settle event.
  static bool tapSettleIsLinked({
    required List<TugboatEvent> events,
    required TugboatEvent tap,
    required TugboatEvent settle,
  }) {
    if (tap.type != 'tap' || settle.type != 'tap_settled') return false;
    if (settle.relatedEventId != tap.id) return false;
    if (!hasChronologicalChain(
      events: events,
      orderedEventIds: <String>[tap.id, settle.id],
    )) {
      return false;
    }
    return events
            .where(
              (event) =>
                  event.type == 'tap_settled' && event.relatedEventId == tap.id,
            )
            .length ==
        1;
  }

  /// Rejects an action which substitutes an origin or unrelated frame for the
  /// destination route epoch.
  static bool hasNoCrossRouteFrameSubstitution({
    required TugboatEvent event,
    required String? originFrameId,
    required String? destinationFrameId,
    required HarnessFrameProvenance? Function(String? frameId)
    frameProvenanceFor,
  }) => actionFrameMatchesRoute(
    action: event,
    originFrameId: originFrameId,
    destinationFrameId: destinationFrameId,
    frameProvenanceFor: frameProvenanceFor,
  );

  /// A missing after-frame is valid only when the event says why, without
  /// leaking an implementation error or pretending it captured evidence.
  static bool hasExplicitDegradation(TugboatEvent event) {
    if (event.afterFrame != null) return false;
    final outcome = event.data['captureOutcome'];
    if (outcome is! String || outcome.isEmpty || outcome == 'captured') {
      return false;
    }
    if (event.type == 'tap_settled' &&
        event.result != TugboatInteractionResult.unknown) {
      return false;
    }
    return true;
  }

  /// Ensures every controller-owned capture path has drained.
  ///
  /// [ControllableCaptureExecutor] is also included because a blocked test
  /// executor otherwise masks a stranded controller waiter.
  static bool hasNoStrandedCaptureWork(ReplayCoherenceHarness harness) =>
      !harness.controller.debugCaptureInFlight &&
      !harness.controller.debugRouteCapturePending &&
      harness.controller.debugActiveTapSettleCount == 0 &&
      harness.controller.debugScheduledCaptureRoutes.isEmpty &&
      !harness.scheduler.hasPendingDelays &&
      harness.capturer.blockedCount == 0;

  /// Tap settle evidence belongs to one route epoch.
  ///
  /// Proves [tap.beforeFrame], [settle.beforeFrame], and [settle.afterFrame]
  /// all belong to [expectedRoute] + [expectedRouteEpoch], while allowing
  /// distinct capture ids/content hashes within that provenance.
  static bool tapSettleIsRouteCoherent({
    required TugboatEvent tap,
    required TugboatEvent settle,
    required String expectedRoute,
    required int expectedRouteEpoch,
    required HarnessFrameProvenance? Function(String? frameId)
    frameProvenanceFor,
    String? expectedRouteSignature,
  }) {
    if (tap.type != 'tap' || settle.type != 'tap_settled') return false;
    if (settle.relatedEventId != tap.id) return false;
    if (settle.beforeFrame != tap.beforeFrame) return false;
    if (expectedRouteSignature != null &&
        settle.stateAnchor?.signature != expectedRouteSignature) {
      return false;
    }
    if (settle.afterFrame == null) return false;

    final frameIds = <String>[
      if (tap.beforeFrame != null) tap.beforeFrame!,
      if (settle.beforeFrame != null) settle.beforeFrame!,
      settle.afterFrame!,
    ];
    if (frameIds.length < 3) return false;

    return eventFramesMatchRoute(
          event: tap,
          expectedRoute: expectedRoute,
          expectedRouteEpoch: expectedRouteEpoch,
          frameProvenanceFor: frameProvenanceFor,
        ) &&
        eventFramesMatchRoute(
          event: settle,
          expectedRoute: expectedRoute,
          expectedRouteEpoch: expectedRouteEpoch,
          frameProvenanceFor: frameProvenanceFor,
        );
  }

  /// Destination-route actions must carry destination-frame provenance.
  ///
  /// Every present action frame must belong to the destination route+epoch
  /// identified by [destinationFrameId]. [originFrameId] is used to reject
  /// origin-route frames even when content hashes collide.
  static bool actionFrameMatchesRoute({
    required TugboatEvent action,
    required String? originFrameId,
    required String? destinationFrameId,
    required HarnessFrameProvenance? Function(String? frameId)
    frameProvenanceFor,
  }) {
    if (destinationFrameId == null) return false;
    final destination = frameProvenanceFor(destinationFrameId);
    if (destination == null) return false;

    final origin = originFrameId == null
        ? null
        : frameProvenanceFor(originFrameId);
    final frameIds = <String>[
      if (action.beforeFrame != null) action.beforeFrame!,
      if (action.afterFrame != null) action.afterFrame!,
    ];
    if (frameIds.isEmpty) return false;

    for (final frameId in frameIds) {
      final provenance = frameProvenanceFor(frameId);
      if (provenance == null) return false;
      if (provenance.route != destination.route ||
          provenance.routeEpoch != destination.routeEpoch) {
        return false;
      }
      if (origin != null &&
          provenance.route == origin.route &&
          provenance.routeEpoch == origin.routeEpoch &&
          (destination.route != origin.route ||
              destination.routeEpoch != origin.routeEpoch)) {
        return false;
      }
    }
    return true;
  }

  /// Navigation-producing taps must not emit an unrelated noVisibleChange.
  ///
  /// Harness causality contract: when expectations are provided, the exact
  /// destination route event must exist, match [expectedDestinationRoute], and
  /// occur no earlier than the tap. Missing destination/id returns false.
  static bool navigationTapHasNoEarlyNoVisibleChange({
    required List<TugboatEvent> events,
    required String tapEventId,
    String? expectedDestinationRoute,
    String? expectedRouteEventId,
  }) {
    final tap = events.cast<TugboatEvent?>().firstWhere(
      (event) => event?.id == tapEventId,
      orElse: () => null,
    );
    if (tap == null) return false;

    final settle = events.cast<TugboatEvent?>().firstWhere(
      (event) =>
          event?.type == 'tap_settled' && event?.relatedEventId == tapEventId,
      orElse: () => null,
    );
    if (settle == null) return false;
    if (settle.relatedEventId != tapEventId) return false;

    if (expectedDestinationRoute == null || expectedRouteEventId == null) {
      return false;
    }

    final routeEvent = events.cast<TugboatEvent?>().firstWhere(
      (event) => event?.id == expectedRouteEventId,
      orElse: () => null,
    );
    if (routeEvent == null) return false;
    if (routeEvent.type != 'route_change') return false;
    if (routeEvent.data['route'] != expectedDestinationRoute) return false;
    if (routeEvent.atMs < tap.atMs) return false;

    return settle.result != TugboatInteractionResult.noVisibleChange;
  }
}
