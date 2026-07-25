import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'capture_profile.dart';
import 'capture_sink.dart';
import 'collector_http_sink.dart';
import 'debug_logging.dart';
import 'exploration_sink.dart';
import 'health.dart';
import 'models.dart';
import 'outbox/outbox.dart';
import 'outbox/outbox_sink.dart';
import 'replay_config.dart';
import 'screenshot_capturer.dart';
import 'scroll_capture.dart';
import 'viewport_semantic_session.dart';

export 'replay_config.dart'
    show
        TugboatReplayConfig,
        TugboatViewportSemanticMode,
        TugboatViewportSemanticPolicy,
        resolveViewportSemanticPolicy;

class _PendingTap {
  _PendingTap({
    required this.eventId,
    required this.targetAnchor,
    required this.beforeState,
    required this.beforeFrame,
    required this.startPosition,
    required this.startedAtMs,
  });

  final String eventId;
  final TugboatTargetAnchor? targetAnchor;
  final TugboatStateAnchor? beforeState;
  final String? beforeFrame;
  final Offset startPosition;
  final int startedAtMs;
  bool suppressSettle = false;
}

class _PointerGestureState {
  _PointerGestureState({required this.tapEventId});

  final String tapEventId;
  final List<String> scrollStartEventIds = [];
}

class _ScrollTracker {
  _ScrollTracker({
    required this.scrollableElement,
    required this.startEventId,
    required this.startedAtMs,
    required this.startOffset,
    required this.beforeFrame,
    required this.targetAnchor,
    required this.sectionLabel,
    required this.axis,
    required this.depth,
    required this.maxScrollExtent,
    this.pageStart,
  });

  final Element scrollableElement;
  final String startEventId;
  final int startedAtMs;
  final double startOffset;
  final String? beforeFrame;
  final TugboatTargetAnchor? targetAnchor;
  final String? sectionLabel;
  final String axis;
  final int depth;
  final double maxScrollExtent;
  final double? pageStart;
  int overscrollCount = 0;
  DateTime? lastSampleAt;
}

class _ScheduledCapture {
  _ScheduledCapture({
    required this.trigger,
    required this.force,
    required this.notBefore,
  });

  TugboatFrameTrigger trigger;
  bool force;
  DateTime notBefore;
  final List<Completer<String?>> waiters = [];

  void absorb(_ScheduledCapture other) {
    if (_triggerPriority(other.trigger) >= _triggerPriority(trigger)) {
      trigger = other.trigger;
    }
    force = force || other.force;
    if (other.notBefore.isAfter(notBefore)) {
      notBefore = other.notBefore;
    }
    waiters.addAll(other.waiters);
  }

  static int _triggerPriority(TugboatFrameTrigger trigger) {
    switch (trigger) {
      case TugboatFrameTrigger.manual:
        return 6;
      case TugboatFrameTrigger.route:
        return 5;
      case TugboatFrameTrigger.lifecycle:
        return 4;
      case TugboatFrameTrigger.tap:
        return 3;
      case TugboatFrameTrigger.scroll:
        return 2;
      case TugboatFrameTrigger.initial:
        return 1;
    }
  }
}

/// Typed navigator semantics for [TugboatReplayController.route].
enum _RouteNavigationKind {
  push('route_push'),
  replace('route_replace'),
  pop('route_pop'),
  remove('route_remove');

  const _RouteNavigationKind(this.wireName);

  /// The `data.navigation` string emitted on `route_change` events.
  final String wireName;

  static _RouteNavigationKind parse(String type) => values.firstWhere(
    (kind) => kind.wireName == type,
    orElse: () => throw ArgumentError.value(type, 'type', 'unknown route type'),
  );
}

/// A raw navigator callback converted into typed route semantics.
class _RouteTransition {
  const _RouteTransition({
    required this.kind,
    required this.routeName,
    required this.transitionDuration,
  });

  final _RouteNavigationKind kind;
  final String? routeName;
  final Duration transitionDuration;
}

/// A resolved, visible navigation: what to record and how to update
/// [TugboatReplayController._currentRoute].
class _VisibleRouteChange {
  const _VisibleRouteChange({
    required this.previousRoute,
    required this.destinationRoute,
    required this.navigation,
    required this.updatesRoute,
  });

  final String? previousRoute;
  final String? destinationRoute;
  final String navigation;
  final bool updatesRoute;
}

/// The terminal state of a private route-capture barrier.
///
/// This is intentionally not part of the public replay schema. The event
/// writer turns the timeout case into additive `captureOutcome` data.
enum _RouteCaptureOutcome { captured, failed, cancelled, timedOut }

class _RouteCaptureResult {
  const _RouteCaptureResult(this.outcome, {this.frameId});

  final _RouteCaptureOutcome outcome;
  final String? frameId;
}

/// One deferred route capture. Its deadline deliberately runs outside the
/// controller queue so a Navigator transition can never stall tap/scroll work.
class _RouteCaptureWork {
  _RouteCaptureWork({
    required this.epoch,
    required this.change,
    required this.deadline,
  });

  final int epoch;
  final _VisibleRouteChange change;
  final Duration deadline;

  /// Completes once with this epoch's terminal barrier outcome.
  final Completer<_RouteCaptureResult> completer =
      Completer<_RouteCaptureResult>();
  bool cancelled = false;
  void Function()? _cancelDeadline;
  void Function()? _cancelBarrierTimeout;
  void Function()? _cancelCapture;
  _RouteCaptureWork? supersededBy;

  Future<_RouteCaptureResult> get done => completer.future;

  void attachDeadlineCancellation(void Function() cancelDeadline) {
    if (cancelled) {
      cancelDeadline();
      return;
    }
    _cancelDeadline = cancelDeadline;
  }

  void attachCaptureCancellation(void Function() cancelCapture) {
    if (cancelled) {
      cancelCapture();
      return;
    }
    _cancelCapture = cancelCapture;
  }

  void attachBarrierTimeoutCancellation(void Function() cancelTimeout) {
    if (cancelled) {
      cancelTimeout();
      return;
    }
    _cancelBarrierTimeout = cancelTimeout;
  }

  /// Stops transition/capture work without choosing this barrier's terminal
  /// outcome. The absolute barrier timeout uses this before completing as
  /// [timedOut].
  void cancelPendingWork() {
    _cancelDeadline?.call();
    _cancelDeadline = null;
    _cancelCapture?.call();
    _cancelCapture = null;
  }

  void cancel() {
    cancelled = true;
    cancelPendingWork();
    _cancelBarrierTimeout?.call();
    _cancelBarrierTimeout = null;
    if (!completer.isCompleted) {
      completer.complete(
        const _RouteCaptureResult(_RouteCaptureOutcome.cancelled),
      );
    }
  }

  void complete(_RouteCaptureResult result) {
    _cancelDeadline = null;
    _cancelBarrierTimeout?.call();
    _cancelBarrierTimeout = null;
    _cancelCapture = null;
    if (!completer.isCompleted) completer.complete(result);
  }
}

class _TapSettleWork {
  _TapSettleWork({required this.session});

  final TugboatSession? session;
  bool cancelled = false;
  final Completer<void> completer = Completer<void>();
  void Function()? _cancelDeadline;
  void Function()? _cancelCapture;

  void attachCaptureCancellation(void Function() cancel) {
    if (cancelled) {
      cancel();
      return;
    }
    _cancelCapture = cancel;
  }

  void attachDeadlineCancellation(void Function() cancel) {
    if (cancelled) {
      cancel();
      return;
    }
    _cancelDeadline = cancel;
  }

  void cancel() {
    cancelled = true;
    _cancelDeadline?.call();
    _cancelDeadline = null;
    _cancelCapture?.call();
    _cancelCapture = null;
    if (!completer.isCompleted) completer.complete();
  }

  void complete() {
    if (!completer.isCompleted) completer.complete();
  }
}

class TugboatReplayController extends ChangeNotifier {
  // A route capture must never hold replay settlement indefinitely when the
  // platform readback callback is lost. This is deliberately private: #9 owns
  // configurable fresh-paint/readback policy.
  static const Duration _routeCaptureTimeout = Duration(seconds: 5);

  TugboatReplayController({
    required this.config,
    required GlobalKey boundaryKey,
    this.activationRequestId,
    this.sessionEpoch = 0,
  }) : _boundaryKey = boundaryKey;

  final TugboatReplayConfig config;
  final GlobalKey _boundaryKey;

  /// Host-supplied activation / request correlation ID (distinct from capture).
  final String? activationRequestId;

  /// Monotonic gate epoch fencing evidence to this capture mount.
  final int sessionEpoch;

  final Stopwatch _clock = Stopwatch();
  Future<void> _queue = Future.value();
  int _queuedTaskCount = 0;
  Future<void>? _endSessionFuture;

  TugboatSession? _session;
  ScreenshotCapturer? _capturer;
  AnchorResolver? _anchorResolver;
  TugboatCaptureSinkHub? _sinkHub;
  ExplorationCaptureSink? _explorationSink;
  CollectorHttpSink? _collectorHttpSink;
  TugboatOutboxStore? _outboxStore;
  final TugboatScreenshotBudgetTracker _screenshotBudget =
      TugboatScreenshotBudgetTracker();
  final List<TugboatSanitizedFailure> _recentFailures = [];
  final List<TugboatCaptureSink> _builtinSinks = [];
  String? _activeExplorationRunId;
  String? _activeActionId;

  int _id = 0;
  String? _currentRoute;
  TugboatStateAnchor? _currentStateAnchor;
  String? _latestFrameId;
  final Map<int, _PendingTap> _pendingTaps = {};
  final Map<String, String> _hashToFrameId = {};

  bool _disposed = false;
  bool _capturePaused = false;
  bool _explorationFramesSuppressed = false;
  bool _captureInFlight = false;
  int _captureGeneration = 0;
  int _captureFailureCount = 0;
  bool _capturePumpScheduled = false;
  bool _skipCapture = false;
  bool _captureLifecycleActive = true;
  int _captureLifecycleEpoch = 0;
  int _routeEpoch = 0;
  _RouteCaptureWork? _activeRouteCapture;
  final Set<_TapSettleWork> _activeTapSettles = <_TapSettleWork>{};
  final Map<Element, _ScrollTracker> _scrollTrackers = {};
  final Map<int, _PointerGestureState> _activeGestures = {};
  String? _lastCapturedStateSignature;
  final Set<String> _emittedInventories = <String>{};
  SemanticsHandle? _semanticsHandle;
  String? _lastDHash;
  late final ViewportSemanticSession _viewportSemantics =
      ViewportSemanticSession(
        config: config,
        nextEventId: _nextId,
        atMs: () => atMs,
        addEvent: _addEvent,
      );

  _ScheduledCapture? _scheduledCapture;

  BuildContext? navigatorContext;

  TugboatSession? get session => _session;
  bool get recording => _session != null;
  bool get scrolling => _scrollTrackers.isNotEmpty;
  bool get capturePaused => _capturePaused;
  int get atMs => _clock.elapsedMilliseconds;
  String? get currentRoute => _currentRoute;
  TugboatStateAnchor? get currentStateAnchor => _currentStateAnchor;
  String? get latestFrameId => _latestFrameId;

  bool get _viewportSemanticMapDebugLogsEnabled => _viewportSemantics.debugLogs;

  /// Hold Flutter's SemanticsHandle for the whole session only in exploration.
  /// Production acquires/disposes semantics transiently inside the map builder.
  bool get _holdPersistentSemanticsHandle =>
      _viewportSemantics.holdPersistentSemanticsHandle;

  @visibleForTesting
  void debugSetCurrentStateAnchor(TugboatStateAnchor? anchor) {
    _currentStateAnchor = anchor;
  }

  /// When true, [_refreshStateAnchor] keeps the last planted state instead of
  /// rebuilding from the widget tree. Characterization tests use this when
  /// driving the controller without a mounted scene.
  @visibleForTesting
  bool debugFreezeStateAnchor = false;

  @visibleForTesting
  void debugSetExplorationFramesSuppressed(bool suppressed) {
    _explorationFramesSuppressed = suppressed;
  }

  /// Test-only clock for capture scheduling. Defaults to [DateTime.now].
  @visibleForTesting
  DateTime Function()? debugNow;

  /// Test-only delay primitive used by route and capture waits.
  ///
  /// Defaults to [Future.delayed]. Harnesses should make each delay
  /// explicitly advanceable so tests never rely on wall-clock sleeps.
  @visibleForTesting
  Future<void> Function(Duration duration)? debugDelay;

  /// Cancellable route-deadline scheduler used by deterministic tests.
  @visibleForTesting
  ({Future<void> done, void Function() cancel}) Function(Duration duration)?
  debugScheduleDelay;

  /// Test-only capture executor. When set, replaces screenshot readback while
  /// preserving the production request/queue/pending-route control flow.
  @visibleForTesting
  Future<String?> Function({
    required TugboatFrameTrigger trigger,
    required bool force,
  })?
  debugExecuteCapture;

  @visibleForTesting
  int get debugRouteEpoch => _routeEpoch;

  @visibleForTesting
  bool get debugRouteCapturePending => _activeRouteCapture != null;

  @visibleForTesting
  bool get debugCaptureInFlight => _captureInFlight;

  @visibleForTesting
  int get debugActiveTapSettleCount => _activeTapSettles.length;

  @visibleForTesting
  Future<void> drainPointerQueue() async {
    await _queue;
    final settles = _activeTapSettles.toList(growable: false);
    await Future.wait(settles.map((work) => work.completer.future));
    await _queue;
  }

  @visibleForTesting
  Future<void> debugEnqueueTask(String label, Future<void> Function() task) =>
      _enqueue(label, task);

  /// Plants a synthetic frame for characterization tests that drive the
  /// controller without real screenshot readback.
  @visibleForTesting
  String debugSeedFrame({
    String? contentHash,
    TugboatFrameTrigger trigger = TugboatFrameTrigger.manual,
    int width = 10,
    int height = 10,
  }) {
    final session = _session;
    if (session == null) {
      throw StateError('debugSeedFrame requires an active session');
    }
    final frameId = _nextId('frame');
    final hash = contentHash ?? 'hash-$frameId';
    final frame = TugboatFrame(
      id: frameId,
      atMs: atMs,
      width: width,
      height: height,
      contentHash: hash,
      trigger: trigger,
      byteLength: 0,
      captureSessionId: session.id,
    );
    session.frames.add(frame);
    session.frameBytes[frameId] = Uint8List(0);
    _hashToFrameId[hash] = frameId;
    _latestFrameId = frameId;
    return frameId;
  }

  DateTime _now() => debugNow?.call() ?? DateTime.now();

  Future<void> _delay(Duration duration) {
    // Preserve Future.delayed(Duration.zero) yielding semantics; never sync-complete.
    final effective = duration < Duration.zero ? Duration.zero : duration;
    final override = debugDelay;
    if (override != null) return override(effective);
    return Future<void>.delayed(effective);
  }

  ({Future<void> done, void Function() cancel}) _scheduleDelay(
    Duration duration,
  ) {
    final effective = duration < Duration.zero ? Duration.zero : duration;
    final override = debugScheduleDelay;
    if (override != null) return override(effective);

    final completer = Completer<void>();
    final timer = Timer(effective, completer.complete);
    return (
      done: completer.future,
      cancel: () {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
      },
    );
  }

  /// Serializes [task] on the controller queue while guaranteeing that a
  /// failure in one task never poisons the chain: an uncaught error in a
  /// plain `_queue.then(...)` would turn `_queue` into an errored future and
  /// silently skip every later task (tap settles, scroll ends, route
  /// captures) for the rest of the session.
  Future<void> _enqueue(String label, Future<void> Function() task) {
    _queuedTaskCount++;
    _queue = _queue.then((_) => _runQueuedTask(label, task));
    return _queue;
  }

  Future<void> _enqueueReady(String label, Future<void> Function() task) {
    if (_queuedTaskCount > 0) return _enqueue(label, task);
    _queuedTaskCount++;
    _queue = _runQueuedTask(label, task);
    return _queue;
  }

  Future<void> _runQueuedTask(
    String label,
    Future<void> Function() task,
  ) async {
    try {
      await task();
    } catch (error, stackTrace) {
      debugPrint('[tugboat] queued $label task failed: $error\n$stackTrace');
    } finally {
      _queuedTaskCount--;
    }
  }

  @visibleForTesting
  TugboatInteractionResult debugComputeTapSettleResult({
    required TugboatStateAnchor? beforeState,
    required TugboatStateAnchor? afterState,
    required String? beforeFrame,
    required String? afterFrame,
  }) {
    return _computeTapSettleResult(
      beforeState: beforeState,
      afterState: afterState,
      beforeFrame: beforeFrame,
      afterFrame: afterFrame,
    );
  }

  /// Debug helper for host apps to dump current semantic anchors (CLI diffing).
  @visibleForTesting
  Map<String, Object?> debugExportSemanticSnapshot({Offset? tapPoint}) {
    final stateAnchor = _refreshStateAnchor();
    final resolver = _anchorResolver;
    TugboatTargetAnchor? targetAnchor;
    if (tapPoint != null && resolver != null) {
      targetAnchor = resolver.targetAt(tapPoint, route: _currentRoute);
    }

    return {
      'atMs': atMs,
      'route': _currentRoute,
      'frameId': _latestFrameId,
      'stateAnchor': stateAnchor?.toJson(),
      if (tapPoint != null) 'tapPoint': {'x': tapPoint.dx, 'y': tapPoint.dy},
      if (targetAnchor != null) 'targetAnchor': targetAnchor.toJson(),
    };
  }

  GlobalKey get boundaryKey => _boundaryKey;

  Future<void> initialize() async {
    final budget = config.screenshotBudget;
    _screenshotBudget
      ..window = budget.window
      ..budgetMicros = budget.budgetMicros;
    final resolver = AnchorResolver(
      rootKey: _boundaryKey,
      widgetNames: config.widgetNames,
    );
    _anchorResolver = resolver;
    _capturer = ScreenshotCapturer(
      boundaryKey: _boundaryKey,
      pixelRatio: config.capturePixelRatio,
      maskLevel: config.effectiveScreenshotMaskLevel,
      anchorResolver: resolver,
    );
    final sinks = <TugboatCaptureSink>[];
    final collectorUrl = config.explorationCollectorUrl;
    if (collectorUrl != null) {
      _explorationSink = ExplorationCaptureSink(
        url: collectorUrl,
        runId: config.explorationRunId,
        onControl: handleExplorationControl,
        onConnected: _handleExplorationCollectorConnected,
        onDisconnected: _handleExplorationCollectorDisconnected,
      );
      sinks.add(_explorationSink!);
      unawaited(_explorationSink!.connect());
    }
    final collectorConfig = config.collector;
    if (collectorConfig != null) {
      _collectorHttpSink = CollectorHttpSink(
        config: collectorConfig.withUserId(config.userId),
      );
      TugboatCaptureSink httpSink = _collectorHttpSink!;
      if (config.outbox.enabled) {
        _outboxStore = TugboatOutboxStore(
          config: config.outbox,
          directory: config.outbox.directory,
        );
        httpSink = OutboxBackedCaptureSink(
          inner: httpSink,
          store: _outboxStore!,
        );
      }
      sinks.add(httpSink);
    }
    _builtinSinks
      ..clear()
      ..addAll(sinks);
    if (sinks.isNotEmpty || config.sinkFactories.isNotEmpty) {
      _sinkHub = TugboatCaptureSinkHub(sinks);
    }
    if (_holdPersistentSemanticsHandle) {
      _semanticsHandle = SemanticsBinding.instance.ensureSemantics();
    }
  }

  Future<void> clearDurableOutbox() async {
    await _outboxStore?.clear();
  }

  TugboatSdkHealth healthSnapshot() {
    final outbox = _outboxStore;
    return TugboatSdkHealth(
      lifecycle: _session == null ? 'dormant' : 'active',
      profile: config.profile.name,
      activationRequestId: activationRequestId,
      captureSessionId: _session?.id,
      sinks: TugboatSinkHealth(
        pending: _sinkHub?.pendingCount ?? 0,
        accepted: _sinkHub?.acceptCount ?? 0,
        dropped: _sinkHub?.dropCount ?? 0,
      ),
      outbox: outbox == null
          ? null
          : TugboatOutboxHealth(
              enabled: config.outbox.enabled,
              pending: outbox.entryCount,
              bytes: outbox.byteSize,
              quarantined: outbox.quarantineReasons.length,
            ),
      screenshots: _screenshotBudget.snapshot(),
      truncated: _session?.truncated ?? false,
      recentFailures: List.unmodifiable(_recentFailures),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    final hub = _sinkHub;
    final ending = endSession();
    _disposed = true;
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
    _sinkHub = null;
    _session = null;
    _cancelScheduledCaptureWaiters();
    if (hub != null) {
      unawaited(ending.whenComplete(hub.dispose));
    }
    _explorationSink = null;
    _collectorHttpSink = null;
    super.dispose();
  }

  /// Emits the final timeline event and flushes lifecycle output once.
  Future<void> endSession() {
    final active = _endSessionFuture;
    if (active != null) return active;
    if (_session == null) return Future<void>.value();

    _cancelActiveTapSettles();
    _cancelActiveRouteCapture();
    _invalidateCaptureWork();
    _captureLifecycleActive = false;

    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'session_end',
        stateAnchor: _currentStateAnchor,
      ),
    );
    final future = _sinkHub?.endSession() ?? Future<void>.value();
    _endSessionFuture = future;
    return future;
  }

  /// Pushes buffered capture output without closing the session.
  Future<void> flushCapture() {
    return _sinkHub?.flush() ?? Future<void>.value();
  }

  void setCapturePaused(bool paused) {
    _capturePaused = paused;
  }

  void start(Size viewport, String platform) {
    _cancelActiveTapSettles();
    _cancelActiveRouteCapture();
    _captureLifecycleActive = true;
    _captureLifecycleEpoch++;
    _endSessionFuture = null;
    _clock
      ..reset()
      ..start();
    _session = TugboatSession(
      id: 'session-${DateTime.now().microsecondsSinceEpoch}',
      startedAt: DateTime.now(),
      platform: platform,
      viewport: TugboatRect(0, 0, viewport.width, viewport.height),
      appInfo: config.appInfo ?? config.collector?.appInfo,
      activationRequestId: activationRequestId,
      explorationRunId: config.explorationRunId,
    );
    _currentRoute = null;
    _currentStateAnchor = null;
    _latestFrameId = null;
    _pendingTaps.clear();
    _scrollTrackers.clear();
    _activeGestures.clear();
    _hashToFrameId.clear();
    _lastCapturedStateSignature = null;
    _emittedInventories.clear();
    _viewportSemantics.clear();
    _lastDHash = null;
    if (!_disposed) notifyListeners();

    final context = TugboatSinkSessionContext(
      captureSessionId: _session!.id,
      sessionEpoch: sessionEpoch,
      activationRequestId: activationRequestId,
      explorationRunId: config.explorationRunId,
      profileName: config.profile.name,
    );
    if (config.sinkFactories.isNotEmpty) {
      final all = <TugboatCaptureSink>[
        ..._builtinSinks,
        for (final factory in config.sinkFactories)
          _FactorySinkAdapter(factory.create(context), context),
      ];
      _sinkHub = TugboatCaptureSinkHub(all);
    }
    _sinkHub?.startSession(_session!);
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'session_start',
        stateAnchor: _refreshStateAnchor(),
      ),
    );
    unawaited(
      _requestCapture(
        trigger: TugboatFrameTrigger.initial,
        settleDelay: Duration.zero,
      ).then((_) {
        _maybeEmitSceneInventory();
      }),
    );
  }

  void clear() {
    final current = _session;
    if (current == null) return;
    start(
      Size(current.viewport.width, current.viewport.height),
      current.platform,
    );
  }

  TugboatStateAnchor? _refreshStateAnchor() {
    if (debugFreezeStateAnchor) return _currentStateAnchor;
    final resolver = _anchorResolver;
    if (resolver == null) return _currentStateAnchor;
    final keyboardOpen = _isKeyboardOpen();
    final modalOpen = _isModalOpen();
    _currentStateAnchor = resolver.buildStateAnchor(
      route: _currentRoute,
      keyboardOpen: keyboardOpen,
      modalOpen: modalOpen,
    );
    return _currentStateAnchor;
  }

  bool _isKeyboardOpen() {
    final context = _boundaryKey.currentContext;
    if (context == null) return false;
    return MediaQuery.viewInsetsOf(context).bottom > 0;
  }

  bool _isModalOpen() {
    final context = navigatorContext ?? _boundaryKey.currentContext;
    if (context == null) return false;
    return ModalRoute.of(context)?.isCurrent == false;
  }

  Future<String?> _requestCapture({
    required TugboatFrameTrigger trigger,
    bool force = false,
    Duration? settleDelay,
  }) {
    return _requestCaptureCancellable(
      trigger: trigger,
      force: force,
      settleDelay: settleDelay,
    ).done;
  }

  ({Future<String?> done, void Function() cancel}) _requestCaptureCancellable({
    required TugboatFrameTrigger trigger,
    bool force = false,
    Duration? settleDelay,
  }) {
    if (_disposed ||
        _capturePaused ||
        _skipCapture ||
        _shouldSuppressFrameCapture) {
      _refreshStateAnchor();
      _maybeEmitSceneInventory();
      return (done: Future<String?>.value(_latestFrameId), cancel: () {});
    }

    final delay = settleDelay ?? config.settleDelay;
    final notBefore = _now().add(delay);
    final completer = Completer<String?>();
    final incoming = _ScheduledCapture(
      trigger: trigger,
      force: force,
      notBefore: notBefore,
    )..waiters.add(completer);

    final scheduled = _scheduledCapture;
    if (scheduled == null) {
      _scheduledCapture = incoming;
    } else {
      scheduled.absorb(incoming);
    }

    _ensureCapturePumpScheduled();
    return (
      done: completer.future,
      cancel: () {
        final scheduled = _scheduledCapture;
        scheduled?.waiters.remove(completer);
        if (scheduled != null && scheduled.waiters.isEmpty) {
          _scheduledCapture = null;
        }
        if (!completer.isCompleted) completer.complete(_latestFrameId);
      },
    );
  }

  void _ensureCapturePumpScheduled() {
    if (_capturePumpScheduled) return;
    _capturePumpScheduled = true;
    scheduleMicrotask(_pumpCaptureScheduler);
  }

  Future<void> _pumpCaptureScheduler() async {
    _capturePumpScheduled = false;
    while (!_disposed && _scheduledCapture != null) {
      final scheduled = _scheduledCapture!;
      final wait = scheduled.notBefore.difference(_now());
      if (wait > Duration.zero) {
        await _delay(wait);
      }
      if (_disposed) break;

      if (!identical(scheduled, _scheduledCapture)) {
        continue;
      }

      if (_captureInFlight) {
        await _waitForCaptureIdle();
        continue;
      }

      _scheduledCapture = null;
      String? frameId;
      try {
        frameId = await _executeCapture(
          trigger: scheduled.trigger,
          force: scheduled.force,
        );
      } catch (error, stackTrace) {
        // A capture failure must not kill the pump loop or strand waiters:
        // stranded waiters would freeze the controller queue permanently.
        debugPrint('[tugboat] capture failed: $error\n$stackTrace');
        _captureFailureCount++;
        frameId = _latestFrameId;
      }
      for (final waiter in scheduled.waiters) {
        if (!waiter.isCompleted) {
          waiter.complete(frameId);
        }
      }
    }
  }

  Future<void> _waitForCaptureIdle() async {
    while (_captureInFlight && !_disposed) {
      await _delay(const Duration(milliseconds: 16));
    }
  }

  void _cancelScheduledCaptureWaiters() {
    final scheduled = _scheduledCapture;
    _scheduledCapture = null;
    if (scheduled == null) return;
    for (final waiter in scheduled.waiters) {
      if (!waiter.isCompleted) waiter.complete(_latestFrameId);
    }
  }

  void _invalidateCaptureWork() {
    _captureGeneration++;
    _captureLifecycleEpoch++;
    _cancelScheduledCaptureWaiters();
  }

  Future<String?> _executeCapture({
    required TugboatFrameTrigger trigger,
    bool force = false,
  }) async {
    final captureGeneration = _captureGeneration;
    final captureSession = _session;
    final captureOverride = debugExecuteCapture;
    if (captureOverride != null) {
      if (_disposed ||
          _capturePaused ||
          _skipCapture ||
          _shouldSuppressFrameCapture ||
          _captureInFlight) {
        return _latestFrameId;
      }
      _captureInFlight = true;
      try {
        // Match the production capture path: refresh state before capture and
        // emit inventory after, so the override seam does not leave anchors
        // stale relative to real screenshot execution.
        _refreshStateAnchor();
        final frameId = await captureOverride(trigger: trigger, force: force);
        if (captureGeneration != _captureGeneration ||
            !identical(_session, captureSession)) {
          return _latestFrameId;
        }
        if (frameId != null) {
          _latestFrameId = frameId;
        }
        _maybeEmitSceneInventory();
        return frameId ?? _latestFrameId;
      } finally {
        _captureInFlight = false;
        if (_scheduledCapture != null) {
          _ensureCapturePumpScheduled();
        }
      }
    }

    if (_disposed ||
        _capturePaused ||
        _skipCapture ||
        _shouldSuppressFrameCapture ||
        _captureInFlight) {
      return _latestFrameId;
    }
    final session = captureSession;
    final capturer = _capturer;
    if (session == null || capturer == null) return _latestFrameId;

    final eligibleToSkip =
        !force &&
        trigger != TugboatFrameTrigger.initial &&
        trigger != TugboatFrameTrigger.lifecycle &&
        config.screenshotBudget.skipEligibleWhenDegraded &&
        _screenshotBudget.shouldSkipEligible;
    if (eligibleToSkip) {
      _screenshotBudget.record(
        queueWaitMicros: 0,
        readbackMicros: 0,
        encodeMicros: 0,
        encodedBytes: 0,
        dropReason: 'budget',
      );
      _refreshStateAnchor();
      _maybeEmitSceneInventory();
      return _latestFrameId;
    }

    final queueStarted = DateTime.now();
    await capturer.waitForFrameBudget();
    final queueWaitMicros = DateTime.now()
        .difference(queueStarted)
        .inMicroseconds;
    if (_disposed ||
        _capturePaused ||
        _skipCapture ||
        captureGeneration != _captureGeneration ||
        !identical(_session, session)) {
      return _latestFrameId;
    }
    _refreshStateAnchor();
    final signature = _currentStateAnchor?.signature ?? '';
    if (!force &&
        trigger != TugboatFrameTrigger.initial &&
        signature.isNotEmpty &&
        signature == _lastCapturedStateSignature) {
      return _latestFrameId;
    }

    _captureInFlight = true;
    try {
      final result = await capturer.capture(
        lastDHash: _lastDHash,
        force: force,
        waitForFrame: false,
      );
      if (result == null ||
          _disposed ||
          captureGeneration != _captureGeneration ||
          !identical(_session, session)) {
        return _latestFrameId;
      }
      final activeSession = session;

      _screenshotBudget.record(
        queueWaitMicros: queueWaitMicros,
        readbackMicros: result.captureMicros,
        encodeMicros: result.encodeMicros,
        encodedBytes: result.bytes.length,
        coalescedCapture: result.skippedByDHash,
      );

      if (result.skippedByDHash) {
        if (result.dHash != null) {
          _lastDHash = result.dHash;
        }
        return _latestFrameId;
      }

      final existingId = _hashToFrameId[result.contentHash];
      if (!force && existingId != null) {
        _latestFrameId = existingId;
        if (result.dHash != null) {
          _lastDHash = result.dHash;
        }
        if (signature.isNotEmpty) {
          _lastCapturedStateSignature = signature;
        }
        _maybeEmitSceneInventory();
        return existingId;
      }

      final frameId = _nextId('frame');
      final frame = TugboatFrame(
        id: frameId,
        atMs: atMs,
        width: result.width,
        height: result.height,
        contentHash: result.contentHash,
        masked: result.masked,
        trigger: trigger,
        byteLength: result.bytes.length,
        captureMicros: result.captureMicros + result.encodeMicros,
        captureSessionId: activeSession.id,
      );
      activeSession.frames.add(frame);
      activeSession.frameBytes[frameId] = result.bytes;
      _hashToFrameId[result.contentHash] = frameId;
      _latestFrameId = frameId;
      if (result.dHash != null) {
        _lastDHash = result.dHash;
      }
      if (signature.isNotEmpty) {
        _lastCapturedStateSignature = signature;
      }
      _maybeEmitSceneInventory();
      _sinkHub?.recordFrame(
        frame,
        result.bytes,
        sessionId: activeSession.id,
        actionId: _activeActionId,
      );
      _trim();
      if (!_disposed) notifyListeners();
      return frameId;
    } finally {
      _captureInFlight = false;
      if (_scheduledCapture != null) {
        _ensureCapturePumpScheduled();
      }
    }
  }

  void recordPointerDown(Offset position, {int pointer = 0}) {
    final resolver = _anchorResolver;
    TugboatTargetAnchor? target;
    TugboatStateAnchor? tapState = _currentStateAnchor;
    TugboatSceneInventory? tapInventory;

    if (resolver != null && config.profile != TugboatCaptureProfile.dormant) {
      final tapContext = resolver.buildTapContext(
        tapPosition: position,
        route: _currentRoute,
        keyboardOpen: _isKeyboardOpen(),
        modalOpen: _isModalOpen(),
      );
      target = tapContext.target;
      tapInventory = tapContext.inventory;
      if (tapInventory != null) {
        _currentStateAnchor = tapInventory.stateAnchor;
        tapState = tapInventory.stateAnchor;
        _emitSceneInventory(tapInventory, emitViewportSemanticMap: false);
      }
    } else {
      target = resolver?.targetAt(position, route: _currentRoute);
    }

    // Resolve after the tap context so a stale settled map can be refreshed
    // against the tap-time inventory state.
    final viewportResolution = _viewportSemantics.resolveTap(
      position: position,
      resolver: _anchorResolver,
      boundaryKey: _boundaryKey,
      inventory: tapInventory,
    );

    final tapData = <String, Object?>{
      'x': position.dx,
      'y': position.dy,
      if (viewportResolution != null)
        'viewportSemanticResolution': viewportResolution.toJson(),
    };

    final beforeFrame = _latestFrameId;
    final beforeState = tapState;
    final eventId = _nextId('event');
    _pendingTaps[pointer] = _PendingTap(
      eventId: eventId,
      targetAnchor: target,
      beforeState: beforeState,
      beforeFrame: beforeFrame,
      startPosition: position,
      startedAtMs: atMs,
    );
    _activeGestures[pointer] = _PointerGestureState(tapEventId: eventId);
    if (target == null) {
      _addEvent(
        TugboatEvent(
          id: _nextId('event'),
          atMs: atMs,
          type: 'tap_outside_tree',
          stateAnchor: beforeState,
          beforeFrame: beforeFrame,
          data: {'x': position.dx, 'y': position.dy, 'pointer': pointer},
        ),
      );
    }
    _addEvent(
      TugboatEvent(
        id: eventId,
        atMs: atMs,
        type: 'tap',
        stateAnchor: beforeState,
        targetAnchor: target,
        beforeFrame: beforeFrame,
        data: tapData,
      ),
    );
    if (viewportResolution != null && _viewportSemanticMapDebugLogsEnabled) {
      tugboatLogViewportSemanticTapResolution(position, viewportResolution);
    }
    if (!_disposed) notifyListeners();
  }

  void recordPointerCancel(Offset position, {int pointer = 0}) {
    _pendingTaps.remove(pointer);
    _activeGestures.remove(pointer);
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'pointer_cancel',
        stateAnchor: _currentStateAnchor,
        data: {'x': position.dx, 'y': position.dy, 'pointer': pointer},
      ),
    );
    if (!_disposed) notifyListeners();
  }

  void markPendingTapAsSwipe(int pointer) {
    final pending = _pendingTaps[pointer];
    if (pending != null) {
      pending.suppressSettle = true;
    }
  }

  void recordPointerUp(Offset position, {int pointer = 0}) {
    final pending = _pendingTaps.remove(pointer);
    final gesture = _activeGestures.remove(pointer);
    if (pending == null) return;

    if (pending.suppressSettle) {
      final delta = position - pending.startPosition;
      final durationMs = atMs - pending.startedAtMs;
      final velocity = durationMs > 0
          ? delta.distance / (durationMs / 1000)
          : 0.0;
      final scrollStartEventId = gesture?.scrollStartEventIds.isNotEmpty == true
          ? gesture!.scrollStartEventIds.first
          : null;
      final scrolled = scrollStartEventId != null;
      _addEvent(
        TugboatEvent(
          id: _nextId('event'),
          atMs: atMs,
          type: 'swipe',
          stateAnchor: _refreshStateAnchor(),
          targetAnchor: pending.targetAnchor,
          beforeFrame: pending.beforeFrame,
          relatedEventId: pending.eventId,
          result: scrolled
              ? TugboatInteractionResult.changed
              : TugboatInteractionResult.noVisibleChange,
          data: {
            'x': position.dx,
            'y': position.dy,
            'startX': pending.startPosition.dx,
            'startY': pending.startPosition.dy,
            'deltaX': delta.dx,
            'deltaY': delta.dy,
            'direction': tugboatSwipeDirection(delta),
            'distance': delta.distance,
            'velocity': velocity,
            'durationMs': durationMs,
            'scrolled': scrolled,
            if (scrollStartEventId != null)
              'scrollStartEventId': scrollStartEventId,
          },
        ),
      );
      if (!_disposed) notifyListeners();
      return;
    }

    final work = _TapSettleWork(session: _session);
    _activeTapSettles.add(work);
    unawaited(_resolveTapSettle(work, pending, position, _activeRouteCapture));
  }

  Future<void> _resolveTapSettle(
    _TapSettleWork work,
    _PendingTap pending,
    Offset position,
    _RouteCaptureWork? routeCaptureAtPointerUp,
  ) async {
    try {
      // Give a callback immediately after pointer-up the same settle boundary.
      if (routeCaptureAtPointerUp == null &&
          config.settleDelay > Duration.zero) {
        final deadline = _scheduleDelay(config.settleDelay);
        work.attachDeadlineCancellation(deadline.cancel);
        await deadline.done;
      }
      if (!_isActiveTapSettle(work)) return;
      final routeCapture = routeCaptureAtPointerUp ?? _activeRouteCapture;
      final String? afterFrame;
      if (routeCapture != null) {
        afterFrame = await _awaitRouteCaptureBarrier(routeCapture);
        if (afterFrame == null || !_isActiveTapSettle(work)) return;
      } else {
        _refreshStateAnchor();
        final capture = _requestCaptureCancellable(
          trigger: TugboatFrameTrigger.tap,
          settleDelay: Duration.zero,
        );
        work.attachCaptureCancellation(capture.cancel);
        afterFrame = await capture.done;
        if (!_isActiveTapSettle(work)) return;
      }
      await _enqueue('tap_settled', () async {
        if (!_isActiveTapSettle(work)) return;
        final beforeState = pending.beforeState;
        final beforeFrame = pending.beforeFrame;
        final tapEventId = pending.eventId;
        final tapTargetAnchor = pending.targetAnchor;
        final afterState = _currentStateAnchor;
        final result = _computeTapSettleResult(
          beforeState: beforeState,
          afterState: afterState,
          beforeFrame: beforeFrame,
          afterFrame: afterFrame,
        );

        _addEvent(
          TugboatEvent(
            id: _nextId('event'),
            atMs: atMs,
            type: 'tap_settled',
            stateAnchor: afterState,
            targetAnchor: tapTargetAnchor,
            beforeFrame: beforeFrame,
            afterFrame: afterFrame,
            result: result,
            relatedEventId: tapEventId,
            data: {'x': position.dx, 'y': position.dy},
          ),
        );
        _maybeEmitStateChange(
          beforeState: beforeState,
          afterState: afterState,
          beforeFrame: beforeFrame,
          afterFrame: afterFrame,
        );
        if (!_disposed) notifyListeners();
      });
    } finally {
      _activeTapSettles.remove(work);
      work.complete();
    }
  }

  bool _isActiveTapSettle(_TapSettleWork work) =>
      !work.cancelled &&
      !_disposed &&
      _captureLifecycleActive &&
      _endSessionFuture == null &&
      identical(_session, work.session);

  void _cancelActiveTapSettles() {
    for (final work in List<_TapSettleWork>.from(_activeTapSettles)) {
      work.cancel();
    }
    _activeTapSettles.clear();
  }

  TugboatInteractionResult _computeTapSettleResult({
    required TugboatStateAnchor? beforeState,
    required TugboatStateAnchor? afterState,
    required String? beforeFrame,
    required String? afterFrame,
  }) {
    final beforeSig = beforeState?.signature ?? '';
    final afterSig = afterState?.signature ?? '';
    if (beforeSig.isNotEmpty && afterSig.isNotEmpty && beforeSig != afterSig) {
      return TugboatInteractionResult.changed;
    }
    if (afterFrame != null &&
        beforeFrame != null &&
        afterFrame != beforeFrame) {
      return TugboatInteractionResult.changed;
    }
    if (beforeSig.isNotEmpty && afterSig.isNotEmpty) {
      return TugboatInteractionResult.noVisibleChange;
    }
    return TugboatInteractionResult.unknown;
  }

  void _linkScrollStartToActiveGestures(String scrollStartEventId) {
    for (final gesture in _activeGestures.values) {
      gesture.scrollStartEventIds.add(scrollStartEventId);
    }
  }

  Element? _scrollableElementFor(BuildContext? context) {
    if (context is! Element) return null;
    if (context.widget is Scrollable) return context;
    Element? found;
    context.visitAncestorElements((ancestor) {
      if (ancestor.widget is Scrollable) {
        found = ancestor;
        return false;
      }
      return true;
    });
    return found;
  }

  TugboatTargetAnchor? _resolveScrollableAnchor(Element scrollableElement) {
    final resolver = _anchorResolver;
    if (resolver == null || config.profile == TugboatCaptureProfile.dormant) {
      return null;
    }
    return resolver.scrollableAnchorFor(
      scrollableElement,
      route: _currentRoute,
    );
  }

  String? _sectionLabelFor(Element scrollableElement) {
    return _anchorResolver?.subViewLabelFor(scrollableElement);
  }

  Map<String, Object?> _scrollEventData({
    required ScrollMetrics metrics,
    required int depth,
    required _ScrollTracker tracker,
    double? endOffset,
    int? durationMs,
    int? overscrollCount,
  }) {
    final data = tugboatScrollMetricsData(metrics)
      ..['depth'] = depth
      ..['startOffset'] = tracker.startOffset;
    if (endOffset != null) {
      data['endOffset'] = endOffset;
    }
    if (durationMs != null) {
      data['durationMs'] = durationMs;
    }
    if (tracker.pageStart != null) {
      data['pageStart'] = tracker.pageStart;
      if (metrics is PageMetrics) {
        data['pageEnd'] = metrics.page;
      }
    }
    if (tracker.sectionLabel != null) {
      data['sectionLabel'] = tracker.sectionLabel;
    }
    if (overscrollCount != null && overscrollCount > 0) {
      data['overscrollCount'] = overscrollCount;
    }
    data.addAll(tugboatScrollEdgeData(metrics));
    return data;
  }

  TugboatViewportSemanticScrollContext _scrollSemanticContext({
    required String trigger,
    required ScrollMetrics metrics,
    required _ScrollTracker tracker,
    double? endOffset,
  }) {
    final maxExtent = metrics.maxScrollExtent;
    final offsetNorm = maxExtent > 0 ? metrics.pixels / maxExtent : null;
    final startNorm = maxExtent > 0 ? tracker.startOffset / maxExtent : null;
    final endNorm = maxExtent > 0
        ? (endOffset ?? metrics.pixels) / maxExtent
        : null;
    return TugboatViewportSemanticScrollContext(
      trigger: trigger,
      scrollableFingerprint: tracker.targetAnchor?.fingerprint,
      axis: metrics.axis.name,
      offset: metrics.pixels,
      offsetNorm: offsetNorm,
      startOffset: tracker.startOffset,
      endOffset: endOffset,
      depth: tracker.depth,
      observedTopNorm: startNorm != null && endNorm != null
          ? (startNorm < endNorm ? startNorm : endNorm)
          : offsetNorm,
      observedBottomNorm: startNorm != null && endNorm != null
          ? (startNorm > endNorm ? startNorm : endNorm)
          : offsetNorm,
    );
  }

  void recordScrollStart({
    required BuildContext? scrollContext,
    required ScrollMetrics metrics,
    required int depth,
  }) {
    final scrollableElement = _scrollableElementFor(scrollContext);
    if (scrollableElement == null) return;
    if (_scrollTrackers.containsKey(scrollableElement)) return;

    _refreshStateAnchor();
    final targetAnchor = _resolveScrollableAnchor(scrollableElement);
    final sectionLabel = _sectionLabelFor(scrollableElement);
    final beforeFrame = _latestFrameId;
    final startEventId = _nextId('event');
    final pageStart = metrics is PageMetrics ? metrics.page : null;

    final tracker = _ScrollTracker(
      scrollableElement: scrollableElement,
      startEventId: startEventId,
      startedAtMs: atMs,
      startOffset: metrics.pixels,
      beforeFrame: beforeFrame,
      targetAnchor: targetAnchor,
      sectionLabel: sectionLabel,
      axis: metrics.axis.name,
      depth: depth,
      maxScrollExtent: metrics.maxScrollExtent,
      pageStart: pageStart,
    );
    _scrollTrackers[scrollableElement] = tracker;

    final session = _session;
    if (session != null) {
      session.scrollSamples.add(
        TugboatScrollSample(
          atMs: atMs,
          offset: metrics.pixels,
          beforeFrame: beforeFrame,
          scrollableFingerprint: targetAnchor?.fingerprint,
          axis: metrics.axis.name,
          offsetNorm: metrics.maxScrollExtent > 0
              ? metrics.pixels / metrics.maxScrollExtent
              : null,
        ),
      );
      _trimScrollSamples();
    }

    _addEvent(
      TugboatEvent(
        id: startEventId,
        atMs: atMs,
        type: 'scroll_start',
        stateAnchor: _currentStateAnchor,
        targetAnchor: targetAnchor,
        beforeFrame: beforeFrame,
        data: _scrollEventData(
          metrics: metrics,
          depth: depth,
          tracker: tracker,
        ),
      ),
    );
    _maybeEmitSceneInventory(
      scrollContext: _scrollSemanticContext(
        trigger: 'scroll_start',
        metrics: metrics,
        tracker: tracker,
      ),
    );
    _linkScrollStartToActiveGestures(startEventId);
    if (!_disposed) notifyListeners();
  }

  void recordScrollUpdate({
    required BuildContext? scrollContext,
    required ScrollMetrics metrics,
  }) {
    final scrollableElement = _scrollableElementFor(scrollContext);
    if (scrollableElement == null) return;
    final tracker = _scrollTrackers[scrollableElement];
    if (tracker == null) return;

    final session = _session;
    if (session == null || _capturePaused) return;
    if (!config.captureScrollSamples) return;

    final now = DateTime.now();
    if (tracker.lastSampleAt != null &&
        now.difference(tracker.lastSampleAt!) < config.scrollCaptureInterval) {
      return;
    }
    tracker.lastSampleAt = now;

    session.scrollSamples.add(
      TugboatScrollSample(
        atMs: atMs,
        offset: metrics.pixels,
        beforeFrame: tracker.beforeFrame,
        scrollableFingerprint: tracker.targetAnchor?.fingerprint,
        axis: metrics.axis.name,
        offsetNorm: metrics.maxScrollExtent > 0
            ? metrics.pixels / metrics.maxScrollExtent
            : null,
      ),
    );
    _trimScrollSamples();
    unawaited(_requestCapture(trigger: TugboatFrameTrigger.scroll));
    // Debounce semantic/inventory rebuilds during continuous scroll; capture
    // still happens, and scroll_end emits a force update.
    if (!_viewportSemantics.allowScrollSemanticRebuild(
      now,
      config.scrollCaptureInterval,
    )) {
      return;
    }
    _maybeEmitSceneInventory(
      scrollContext: _scrollSemanticContext(
        trigger: 'scroll_update',
        metrics: metrics,
        tracker: tracker,
      ),
    );
  }

  void recordScrollOverscroll({required BuildContext? scrollContext}) {
    final scrollableElement = _scrollableElementFor(scrollContext);
    if (scrollableElement == null) return;
    final tracker = _scrollTrackers[scrollableElement];
    if (tracker == null) return;
    tracker.overscrollCount++;
  }

  void recordScrollEnd({
    required BuildContext? scrollContext,
    required ScrollMetrics metrics,
  }) {
    final scrollableElement = _scrollableElementFor(scrollContext);
    if (scrollableElement == null) return;
    final tracker = _scrollTrackers.remove(scrollableElement);
    if (tracker == null) return;
    final captureSession = _session;
    final captureLifecycleEpoch = _captureLifecycleEpoch;

    _enqueue('scroll_end', () async {
      if (!_isCaptureLifecycleCurrent(captureSession, captureLifecycleEpoch)) {
        return;
      }
      final afterFrame = await _requestCapture(
        trigger: TugboatFrameTrigger.scroll,
        force: true,
      );
      if (!_isCaptureLifecycleCurrent(captureSession, captureLifecycleEpoch)) {
        return;
      }
      if (_session != null && _session!.scrollSamples.isNotEmpty) {
        final last = _session!.scrollSamples.last;
        _session!.scrollSamples[_session!.scrollSamples.length -
            1] = TugboatScrollSample(
          atMs: last.atMs,
          offset: metrics.pixels,
          beforeFrame: last.beforeFrame,
          afterFrame: afterFrame,
          scrollableFingerprint: last.scrollableFingerprint,
          axis: last.axis,
          offsetNorm: last.offsetNorm,
        );
      }
      _maybeEmitSceneInventory(
        scrollContext: _scrollSemanticContext(
          trigger: 'scroll_end',
          metrics: metrics,
          tracker: tracker,
          endOffset: metrics.pixels,
        ),
      );
      _addEvent(
        TugboatEvent(
          id: _nextId('event'),
          atMs: atMs,
          type: 'scroll_end',
          stateAnchor: _refreshStateAnchor(),
          targetAnchor: tracker.targetAnchor,
          beforeFrame: tracker.beforeFrame,
          afterFrame: afterFrame,
          relatedEventId: tracker.startEventId,
          data: _scrollEventData(
            metrics: metrics,
            depth: tracker.depth,
            tracker: tracker,
            endOffset: metrics.pixels,
            durationMs: atMs - tracker.startedAtMs,
            overscrollCount: tracker.overscrollCount,
          ),
        ),
      );
      if (!_disposed) notifyListeners();
    });
  }

  bool _isCaptureLifecycleCurrent(
    TugboatSession? session,
    int lifecycleEpoch,
  ) =>
      !_disposed &&
      _captureLifecycleActive &&
      _endSessionFuture == null &&
      identical(_session, session) &&
      _captureLifecycleEpoch == lifecycleEpoch;

  Future<void> route(String type, Route<dynamic>? route) {
    if (_disposed || _session == null || _endSessionFuture != null) {
      return Future<void>.value();
    }
    final transition = _parseRouteTransition(type, route);
    final change = _resolveVisibleRouteChange(transition);
    if (change == null) return Future<void>.value();

    if (change.updatesRoute) _currentRoute = change.destinationRoute;

    final prior = _activeRouteCapture;
    _cancelActiveRouteCapture();
    final work = _RouteCaptureWork(
      epoch: ++_routeEpoch,
      change: change,
      deadline:
          transition.transitionDuration +
          (_shouldSuppressFrameCapture ? Duration.zero : config.settleDelay),
    );
    _activeRouteCapture = work;
    prior?.supersededBy = work;
    _skipCapture = transition.transitionDuration > Duration.zero;
    _startRouteBarrierTimeout(work);
    if (work.deadline <= Duration.zero) {
      unawaited(_enqueue('route_change', () => _finalizeRouteCapture(work)));
    } else {
      _startRouteDeadline(work);
    }
    return work.done.then<void>((_) {});
  }

  bool _isActiveRouteCapture(_RouteCaptureWork work) =>
      !_disposed && !work.cancelled && identical(_activeRouteCapture, work);

  /// Waits for a route epoch's single capture outcome. If that epoch is
  /// superseded while a tap is waiting, join the replacement epoch instead of
  /// letting the tap fall back to an opportunistic latest frame.
  Future<String?> _awaitRouteCaptureBarrier(_RouteCaptureWork work) async {
    var candidate = work;
    while (true) {
      final result = await candidate.done;
      if (result.outcome == _RouteCaptureOutcome.captured) {
        return result.frameId;
      }
      // Only explicit cancellation from a successor can transfer a waiter.
      // In particular, a timed-out route must not attach a tap to a later,
      // unrelated navigation.
      if (result.outcome != _RouteCaptureOutcome.cancelled) return null;
      final replacement = candidate.supersededBy;
      if (replacement == null || identical(replacement, candidate)) {
        return null;
      }
      candidate = replacement;
    }
  }

  void _cancelActiveRouteCapture() {
    final active = _activeRouteCapture;
    _activeRouteCapture = null;
    if (active != null) _captureGeneration++;
    active?.cancel();
    _skipCapture = false;
  }

  void _startRouteDeadline(_RouteCaptureWork work) {
    final scheduled = _scheduleDelay(work.deadline);
    work.attachDeadlineCancellation(scheduled.cancel);
    unawaited(_awaitRouteDeadline(work, scheduled.done));
  }

  /// Arms one absolute deadline at route creation. It covers Navigator
  /// transition settlement plus a bounded readback allowance, so waiting
  /// route/tap futures cannot be held behind an unrelated controller task.
  void _startRouteBarrierTimeout(_RouteCaptureWork work) {
    final scheduled = _scheduleDelay(work.deadline + _routeCaptureTimeout);
    work.attachBarrierTimeoutCancellation(scheduled.cancel);
    unawaited(_awaitRouteBarrierTimeout(work, scheduled.done));
  }

  Future<void> _awaitRouteBarrierTimeout(
    _RouteCaptureWork work,
    Future<void> timeout,
  ) async {
    try {
      await timeout;
      _timeoutRouteCapture(work);
    } catch (error, stackTrace) {
      debugPrint('[tugboat] route barrier timeout failed: $error\n$stackTrace');
    }
  }

  void _timeoutRouteCapture(_RouteCaptureWork work) {
    if (!_isActiveRouteCapture(work)) return;
    final change = work.change;
    work.cancelPendingWork();
    _captureGeneration++;
    _activeRouteCapture = null;
    _skipCapture = false;
    work.complete(const _RouteCaptureResult(_RouteCaptureOutcome.timedOut));
    _refreshStateAnchor();
    // This must not enqueue behind the blocked task that caused the timeout.
    // Dart's single isolate means the session mutation is still atomic with
    // respect to the next event-loop turn.
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'route_change',
        stateAnchor: _currentStateAnchor,
        result: TugboatInteractionResult.unknown,
        data: {
          if (change.previousRoute != null) 'fromRoute': change.previousRoute,
          if (change.destinationRoute != null) 'route': change.destinationRoute,
          'navigation': change.navigation,
          'captureOutcome': 'timed_out',
        },
      ),
    );
    if (!_disposed) notifyListeners();
  }

  Future<void> _awaitRouteDeadline(
    _RouteCaptureWork work,
    Future<void> deadline,
  ) async {
    try {
      await deadline;
      if (!_isActiveRouteCapture(work)) return;
      _skipCapture = false;
      await _enqueueReady('route_change', () => _finalizeRouteCapture(work));
    } catch (error, stackTrace) {
      debugPrint('[tugboat] route deadline failed: $error\n$stackTrace');
    }
  }

  Future<void> _finalizeRouteCapture(_RouteCaptureWork work) async {
    String? afterFrame;
    var outcome = _RouteCaptureOutcome.failed;
    try {
      if (!_isActiveRouteCapture(work)) return;
      final change = work.change;
      if (change.updatesRoute) _currentRoute = change.destinationRoute;
      _refreshStateAnchor();
      final captureFailureCount = _captureFailureCount;
      final capture = _requestCaptureCancellable(
        trigger: TugboatFrameTrigger.route,
        force: true,
        // The route deadline already includes the configured post-route
        // settle. Scheduling it again here would delay capture twice and can
        // strand widget-backed callers waiting for route completion.
        settleDelay: Duration.zero,
      );
      work.attachCaptureCancellation(capture.cancel);
      final captureResult = await _awaitRouteReadback(work, capture.done);
      if (captureResult.outcome == _RouteCaptureOutcome.failed) {
        if (!_isActiveRouteCapture(work)) return;
        outcome = _RouteCaptureOutcome.failed;
        _addEvent(
          TugboatEvent(
            id: _nextId('event'),
            atMs: atMs,
            type: 'route_change',
            stateAnchor: _currentStateAnchor,
            result: TugboatInteractionResult.navigated,
            data: {
              if (change.previousRoute != null)
                'fromRoute': change.previousRoute,
              if (change.destinationRoute != null)
                'route': change.destinationRoute,
              'navigation': change.navigation,
              'captureOutcome': 'failed',
            },
          ),
        );
        if (!_disposed) notifyListeners();
        return;
      }
      if (captureResult.outcome != _RouteCaptureOutcome.captured) return;
      afterFrame = captureResult.frameId;
      if (_captureFailureCount != captureFailureCount) afterFrame = null;
      outcome = afterFrame == null
          ? _RouteCaptureOutcome.failed
          : _RouteCaptureOutcome.captured;
      if (!_isActiveRouteCapture(work)) return;
      final previousRoute = change.previousRoute;
      final destinationRoute = change.destinationRoute;
      _addEvent(
        TugboatEvent(
          id: _nextId('event'),
          atMs: atMs,
          type: 'route_change',
          stateAnchor: _currentStateAnchor,
          afterFrame: afterFrame,
          result: TugboatInteractionResult.navigated,
          data: {
            if (previousRoute != null) 'fromRoute': previousRoute,
            if (destinationRoute != null) 'route': destinationRoute,
            'navigation': change.navigation,
            if (outcome == _RouteCaptureOutcome.failed)
              'captureOutcome': 'failed',
          },
        ),
      );
      _maybeEmitSceneInventory();
      if (!_disposed) notifyListeners();
    } finally {
      if (identical(_activeRouteCapture, work)) {
        _activeRouteCapture = null;
        _skipCapture = false;
      }
      work.complete(_RouteCaptureResult(outcome, frameId: afterFrame));
    }
  }

  /// Joins readback to the route's absolute terminal barrier. A timeout or
  /// cancellation wakes an already-admitted finalizer immediately instead of
  /// leaving the serialized queue blocked on platform readback.
  Future<_RouteCaptureResult> _awaitRouteReadback(
    _RouteCaptureWork work,
    Future<String?> capture,
  ) async {
    return Future.any<_RouteCaptureResult>([
      capture.then(
        (frameId) => _RouteCaptureResult(
          frameId == null
              ? _RouteCaptureOutcome.failed
              : _RouteCaptureOutcome.captured,
          frameId: frameId,
        ),
        onError: (_, __) =>
            const _RouteCaptureResult(_RouteCaptureOutcome.failed),
      ),
      work.done,
    ]);
  }

  void recordAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _cancelActiveTapSettles();
        _cancelActiveRouteCapture();
        _invalidateCaptureWork();
        _captureLifecycleActive = false;
        break;
      case AppLifecycleState.resumed:
        _captureLifecycleActive = true;
      case AppLifecycleState.inactive:
        break;
    }
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: _appLifecycleEventType(state),
        data: {'state': state.name},
      ),
    );
  }

  String _appLifecycleEventType(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        return 'app_backgrounded';
      case AppLifecycleState.resumed:
        return 'app_foregrounded';
      case AppLifecycleState.inactive:
        return 'app_inactive';
      case AppLifecycleState.detached:
        return 'app_detached';
    }
  }

  _RouteTransition _parseRouteTransition(String type, Route<dynamic>? route) {
    return _RouteTransition(
      kind: _RouteNavigationKind.parse(type),
      routeName: route?.settings.name ?? route?.runtimeType.toString(),
      transitionDuration: route is TransitionRoute<dynamic>
          ? route.transitionDuration
          : Duration.zero,
    );
  }

  /// Resolves [transition] against [_currentRoute], or returns null when it
  /// is not visible navigation.
  ///
  /// Stack-cleanup removals (e.g. `pushNamedAndRemoveUntil` clearing routes
  /// below the new top) resolve to null and must not bump the route epoch:
  /// doing so cancels the pending capture scheduled by the preceding push,
  /// dropping both the route_change event and its screenshot for the
  /// destination route.
  _VisibleRouteChange? _resolveVisibleRouteChange(_RouteTransition transition) {
    final routeName = transition.routeName;
    if (transition.kind == _RouteNavigationKind.remove &&
        (routeName == null || routeName == _currentRoute)) {
      return null;
    }
    // Pop/remove callbacks carry the route that becomes visible; without one
    // there is no destination to record, so the current route is kept.
    final updatesRoute =
        transition.kind == _RouteNavigationKind.push ||
        transition.kind == _RouteNavigationKind.replace ||
        routeName != null;
    return _VisibleRouteChange(
      previousRoute: _currentRoute,
      destinationRoute: updatesRoute ? routeName : _currentRoute,
      navigation: transition.kind.wireName,
      updatesRoute: updatesRoute,
    );
  }

  void _maybeEmitStateChange({
    required TugboatStateAnchor? beforeState,
    required TugboatStateAnchor? afterState,
    required String? beforeFrame,
    required String? afterFrame,
  }) {
    final beforeSignature = beforeState?.signature ?? '';
    final afterSignature = afterState?.signature ?? '';
    if (beforeSignature.isEmpty || afterSignature.isEmpty) return;
    if (beforeSignature == afterSignature) return;

    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'state_change',
        stateAnchor: afterState,
        beforeFrame: beforeFrame,
        afterFrame: afterFrame,
        result: TugboatInteractionResult.changed,
        data: {
          if (afterState?.subLabel != null) 'subLabel': afterState!.subLabel,
        },
      ),
    );
    _maybeEmitSceneInventory();
  }

  void _maybeEmitSceneInventory({
    TugboatViewportSemanticScrollContext? scrollContext,
  }) {
    if (config.profile != TugboatCaptureProfile.exploration) return;
    final resolver = _anchorResolver;
    if (resolver == null || _session == null) return;

    final inventory = resolver.buildSceneInventory(
      route: _currentRoute,
      keyboardOpen: _isKeyboardOpen(),
      modalOpen: _isModalOpen(),
    );
    if (inventory == null) return;

    _currentStateAnchor = inventory.stateAnchor;
    _emitSceneInventory(inventory, scrollContext: scrollContext);
  }

  void _emitSceneInventory(
    TugboatSceneInventory inventory, {
    bool emitViewportSemanticMap = true,
    TugboatViewportSemanticScrollContext? scrollContext,
  }) {
    if (config.profile != TugboatCaptureProfile.exploration) return;
    // Always emit raw scene_inventory first (when new). Semantic-map emission
    // must not replace or suppress inventory — it is the local inventory source
    // of truth; maps are a companion / production bridge.
    final dedupeKey = '${inventory.stateSignature}|${inventory.inventoryHash}';
    if (_emittedInventories.add(dedupeKey)) {
      _addEvent(
        TugboatEvent(
          id: _nextId('event'),
          atMs: atMs,
          type: 'scene_inventory',
          stateAnchor: inventory.stateAnchor,
          data: inventory.toJson(),
        ),
      );
    }
    if (emitViewportSemanticMap) {
      _viewportSemantics.maybeEmit(
        inventory,
        resolver: _anchorResolver,
        scrollContext: scrollContext,
      );
    }
  }

  void _addEvent(TugboatEvent event) {
    final session = _session;
    if (session == null) return;
    final enriched = event.withExplorationContext(
      sessionId: session.id,
      captureSessionId: session.id,
      activationRequestId: session.activationRequestId ?? activationRequestId,
      explorationRunId: _activeExplorationRunId ?? config.explorationRunId,
      actionId: _activeActionId,
    );
    session.events.add(enriched);
    _sinkHub?.recordEvent(enriched);
    _trim();
  }

  void setExplorationActionWindow({
    required String explorationRunId,
    required String actionId,
  }) {
    _activeExplorationRunId = explorationRunId;
    _activeActionId = actionId;
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'action_window_set',
        data: {'actionId': actionId, 'explorationRunId': explorationRunId},
      ),
    );
  }

  void clearExplorationActionWindow() {
    final clearedActionId = _activeActionId;
    if (clearedActionId != null) {
      _addEvent(
        TugboatEvent(
          id: _nextId('event'),
          atMs: atMs,
          type: 'action_window_cleared',
          data: {'actionId': clearedActionId},
        ),
      );
    }
    _activeActionId = null;
  }

  void _handleExplorationCollectorConnected() {
    if (config.collector != null) return;
    _explorationFramesSuppressed = true;
  }

  void _handleExplorationCollectorDisconnected() {
    _explorationFramesSuppressed = false;
  }

  bool get _shouldSuppressFrameCapture =>
      _explorationFramesSuppressed && config.collector == null;

  void handleExplorationControl(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    switch (type) {
      case 'set_action_window':
        final runId = message['explorationRunId'] as String?;
        final actionId = message['actionId'] as String?;
        if (runId != null && actionId != null) {
          setExplorationActionWindow(
            explorationRunId: runId,
            actionId: actionId,
          );
          _explorationSink?.transport.acknowledge(type!, actionId: actionId);
        }
      case 'clear_action_window':
        clearExplorationActionWindow();
        _explorationSink?.transport.acknowledge(
          type!,
          actionId: message['actionId'] as String?,
        );
      case 'pause_capture':
        setCapturePaused(true);
        _explorationSink?.transport.acknowledge(type!);
      case 'resume_capture':
        setCapturePaused(false);
        _explorationSink?.transport.acknowledge(type!);
      default:
        break;
    }
  }

  void _trim() {
    final session = _session;
    if (session == null) return;
    while (session.events.length > config.maxEvents) {
      session.events.removeAt(0);
      session.truncated = true;
    }
    while (session.frames.length > config.maxFrames) {
      final removed = session.frames.removeAt(0);
      session.frameBytes.remove(removed.id);
      _hashToFrameId.remove(removed.contentHash);
      session.truncated = true;
    }
  }

  void _trimScrollSamples() {
    const maxScrollSamples = 200;
    final session = _session;
    if (session == null) return;
    while (session.scrollSamples.length > maxScrollSamples) {
      session.scrollSamples.removeAt(0);
      session.truncated = true;
    }
  }

  String _nextId(String prefix) => '$prefix-${_id++}';
}

/// Adapts a session-owned factory sink to the legacy hub interface.
class _FactorySinkAdapter implements TugboatCaptureSink {
  _FactorySinkAdapter(this._sink, this._context);

  final TugboatSessionCaptureSink _sink;
  final TugboatSinkSessionContext _context;
  bool _finished = false;

  @override
  void startSession(TugboatSession session) {
    // ignore: discarded_futures
    _sink.start(_context);
  }

  @override
  void recordEvent(TugboatEvent event) {
    if (_finished) return;
    _sink.accept(
      TugboatCaptureEnvelope(
        kind: TugboatEnvelopeKind.event,
        captureSessionId: _context.captureSessionId,
        sessionEpoch: _context.sessionEpoch,
        activationRequestId: _context.activationRequestId,
        idempotencyKey: 'event:${event.id}',
        event: event,
      ),
    );
  }

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    if (_finished) return;
    _sink.accept(
      TugboatCaptureEnvelope(
        kind: TugboatEnvelopeKind.frame,
        captureSessionId: _context.captureSessionId,
        sessionEpoch: _context.sessionEpoch,
        activationRequestId: _context.activationRequestId,
        idempotencyKey: 'frame:${frame.id}',
        frame: frame,
        frameBytes: bytes,
        actionId: actionId,
      ),
    );
  }

  @override
  Future<void> flush() => _sink.flush();

  @override
  Future<void> endSession() async {
    if (_finished) return;
    _finished = true;
    await _sink.finish();
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _sink.dispose();
  }
}
