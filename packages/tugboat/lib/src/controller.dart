import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'capture_profile.dart';
import 'capture_sink.dart';
import 'collector_config.dart';
import 'collector_http_sink.dart';
import 'exploration_sink.dart';
import 'models.dart';
import 'screenshot_capturer.dart';
import 'screenshot_mask_level.dart';

import 'scroll_capture.dart';

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

class TugboatReplayConfig {
  const TugboatReplayConfig({
    this.profile = TugboatCaptureProfile.dormant,
    this.settleDelay = const Duration(seconds: 1),
    this.maxFrames = 500,
    this.maxEvents = 5000,
    this.scrollCaptureInterval = const Duration(seconds: 2),
    this.captureScrollSamples = false,
    this.capturePixelRatio = 0.75,
    this.enableGlobalPointerCapture = true,
    this.explorationCollectorUrl,
    this.explorationRunId,
    this.appInfo,
    this.collector,
    this.screenshotMaskLevel,
    this.widgetNames = const {},
    this.enableViewportSemanticMap = false,
    this.enableViewportSemanticMapDebugLogs = false,
  });

  final TugboatCaptureProfile profile;
  final Duration settleDelay;
  final int maxFrames;
  final int maxEvents;
  final Duration scrollCaptureInterval;
  final bool captureScrollSamples;
  final double capturePixelRatio;
  final bool enableGlobalPointerCapture;
  final String? explorationCollectorUrl;
  final String? explorationRunId;
  final TugboatCollectorAppInfo? appInfo;
  final TugboatCollectorConfig? collector;
  final TugboatScreenshotMaskLevel? screenshotMaskLevel;
  final Map<Type, String> widgetNames;
  final bool enableViewportSemanticMap;
  final bool enableViewportSemanticMapDebugLogs;

  TugboatScreenshotMaskLevel get effectiveScreenshotMaskLevel =>
      screenshotMaskLevel ??
      switch (profile) {
        TugboatCaptureProfile.productionLean =>
          TugboatScreenshotMaskLevel.allTextAndMedia,
        TugboatCaptureProfile.dormant || TugboatCaptureProfile.exploration =>
          TugboatScreenshotMaskLevel.explicitOnly,
      };

  TugboatReplayConfig copyWith({
    TugboatCaptureProfile? profile,
    Duration? settleDelay,
    int? maxFrames,
    int? maxEvents,
    Duration? scrollCaptureInterval,
    bool? captureScrollSamples,
    double? capturePixelRatio,
    bool? enableGlobalPointerCapture,
    String? explorationCollectorUrl,
    String? explorationRunId,
    TugboatCollectorAppInfo? appInfo,
    TugboatCollectorConfig? collector,
    TugboatScreenshotMaskLevel? screenshotMaskLevel,
    Map<Type, String>? widgetNames,
    bool? enableViewportSemanticMap,
    bool? enableViewportSemanticMapDebugLogs,
  }) {
    return TugboatReplayConfig(
      profile: profile ?? this.profile,
      settleDelay: settleDelay ?? this.settleDelay,
      maxFrames: maxFrames ?? this.maxFrames,
      maxEvents: maxEvents ?? this.maxEvents,
      scrollCaptureInterval:
          scrollCaptureInterval ?? this.scrollCaptureInterval,
      captureScrollSamples: captureScrollSamples ?? this.captureScrollSamples,
      capturePixelRatio: capturePixelRatio ?? this.capturePixelRatio,
      enableGlobalPointerCapture:
          enableGlobalPointerCapture ?? this.enableGlobalPointerCapture,
      explorationCollectorUrl:
          explorationCollectorUrl ?? this.explorationCollectorUrl,
      explorationRunId: explorationRunId ?? this.explorationRunId,
      appInfo: appInfo ?? this.appInfo,
      collector: collector ?? this.collector,
      screenshotMaskLevel: screenshotMaskLevel ?? this.screenshotMaskLevel,
      widgetNames: widgetNames ?? this.widgetNames,
      enableViewportSemanticMap:
          enableViewportSemanticMap ?? this.enableViewportSemanticMap,
      enableViewportSemanticMapDebugLogs:
          enableViewportSemanticMapDebugLogs ??
          this.enableViewportSemanticMapDebugLogs,
    );
  }
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

class TugboatReplayController extends ChangeNotifier {
  TugboatReplayController({required this.config, required GlobalKey boundaryKey})
    : _boundaryKey = boundaryKey;

  final TugboatReplayConfig config;
  final GlobalKey _boundaryKey;

  final Stopwatch _clock = Stopwatch();
  Future<void> _queue = Future.value();

  TugboatSession? _session;
  ScreenshotCapturer? _capturer;
  AnchorResolver? _anchorResolver;
  TugboatCaptureSinkHub? _sinkHub;
  ExplorationCaptureSink? _explorationSink;
  CollectorHttpSink? _collectorHttpSink;
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
  bool _capturePumpScheduled = false;
  bool _skipCapture = false;
  bool _routeCapturePending = false;
  int _routeEpoch = 0;
  final Map<Element, _ScrollTracker> _scrollTrackers = {};
  final Map<int, _PointerGestureState> _activeGestures = {};
  String? _lastCapturedStateSignature;
  final Set<String> _emittedInventories = <String>{};
  final Set<String> _emittedSemanticMaps = <String>{};
  TugboatViewportSemanticMap? _latestViewportSemanticMap;
  SemanticsHandle? _semanticsHandle;
  String? _lastDHash;

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

  bool get _viewportSemanticMapEnabled =>
      config.enableViewportSemanticMap &&
      config.profile == TugboatCaptureProfile.exploration;

  bool get _viewportSemanticMapDebugLogsEnabled =>
      config.enableViewportSemanticMapDebugLogs && _viewportSemanticMapEnabled;

  @visibleForTesting
  void debugSetCurrentStateAnchor(TugboatStateAnchor? anchor) {
    _currentStateAnchor = anchor;
  }

  @visibleForTesting
  void debugSetExplorationFramesSuppressed(bool suppressed) {
    _explorationFramesSuppressed = suppressed;
  }

  @visibleForTesting
  Future<void> drainPointerQueue() => _queue;

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
    _capturer = ScreenshotCapturer(
      boundaryKey: _boundaryKey,
      pixelRatio: config.capturePixelRatio,
      maskLevel: config.effectiveScreenshotMaskLevel,
    );
    _anchorResolver = AnchorResolver(
      rootKey: _boundaryKey,
      widgetNames: config.widgetNames,
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
      _collectorHttpSink = CollectorHttpSink(config: collectorConfig);
      sinks.add(_collectorHttpSink!);
    }
    if (sinks.isNotEmpty) {
      _sinkHub = TugboatCaptureSinkHub(sinks);
    }
    if (_viewportSemanticMapEnabled) {
      _semanticsHandle = SemanticsBinding.instance.ensureSemantics();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
    _latestViewportSemanticMap = null;
    final hub = _sinkHub;
    _sinkHub = null;
    _session = null;
    _scheduledCapture = null;
    if (hub != null) {
      unawaited(hub.endSession());
      hub.dispose();
    }
    _explorationSink = null;
    _collectorHttpSink = null;
    super.dispose();
  }

  void setCapturePaused(bool paused) {
    _capturePaused = paused;
  }

  void start(Size viewport, String platform) {
    _clock
      ..reset()
      ..start();
    _session = TugboatSession(
      id: 'session-${DateTime.now().microsecondsSinceEpoch}',
      startedAt: DateTime.now(),
      platform: platform,
      viewport: TugboatRect(0, 0, viewport.width, viewport.height),
      appInfo: config.appInfo ?? config.collector?.appInfo,
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
    _emittedSemanticMaps.clear();
    _latestViewportSemanticMap = null;
    _lastDHash = null;
    if (!_disposed) notifyListeners();
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
    if (_disposed ||
        _capturePaused ||
        _skipCapture ||
        _shouldSuppressFrameCapture) {
      _refreshStateAnchor();
      _maybeEmitSceneInventory();
      return Future<String?>.value(_latestFrameId);
    }

    final delay = settleDelay ?? config.settleDelay;
    final notBefore = DateTime.now().add(delay);
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
    return completer.future;
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
      final wait = scheduled.notBefore.difference(DateTime.now());
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
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
      final frameId = await _executeCapture(
        trigger: scheduled.trigger,
        force: scheduled.force,
      );
      for (final waiter in scheduled.waiters) {
        if (!waiter.isCompleted) {
          waiter.complete(frameId);
        }
      }
    }
  }

  Future<void> _waitForCaptureIdle() async {
    while (_captureInFlight && !_disposed) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<String?> _executeCapture({
    required TugboatFrameTrigger trigger,
    bool force = false,
  }) async {
    if (_disposed ||
        _capturePaused ||
        _skipCapture ||
        _shouldSuppressFrameCapture ||
        _captureInFlight) {
      return _latestFrameId;
    }
    final session = _session;
    final capturer = _capturer;
    if (session == null || capturer == null) return _latestFrameId;

    await capturer.waitForFrameBudget();
    if (_disposed || _capturePaused || _skipCapture) return _latestFrameId;
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
      if (result == null || _disposed) return _latestFrameId;
      final activeSession = _session;
      if (activeSession == null) return _latestFrameId;

      if (result.skippedByDHash) {
        _lastDHash = result.dHash;
        return _latestFrameId;
      }

      final existingId = _hashToFrameId[result.contentHash];
      if (!force && existingId != null) {
        _latestFrameId = existingId;
        _lastDHash = result.dHash;
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
      );
      activeSession.frames.add(frame);
      activeSession.frameBytes[frameId] = result.bytes;
      _hashToFrameId[result.contentHash] = frameId;
      _latestFrameId = frameId;
      _lastDHash = result.dHash;
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
        _emitSceneInventory(tapInventory);
      }
    } else {
      target = resolver?.targetAt(position, route: _currentRoute);
    }

    final viewportResolution = _resolveViewportSemanticTap(
      position: position,
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
    if (viewportResolution != null) {
      _logViewportSemanticTapResolution(position, viewportResolution);
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

    _queue = _queue.then((_) async {
      if (_disposed) return;
      final beforeState = pending.beforeState;
      final beforeFrame = pending.beforeFrame;
      final tapEventId = pending.eventId;
      final tapTargetAnchor = pending.targetAnchor;

      final String? afterFrame;
      if (_routeCapturePending) {
        afterFrame = _latestFrameId;
      } else {
        _refreshStateAnchor();
        afterFrame = await _requestCapture(trigger: TugboatFrameTrigger.tap);
      }
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

    _queue = _queue.then((_) async {
      final afterFrame = await _requestCapture(
        trigger: TugboatFrameTrigger.scroll,
        force: true,
      );
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

  Future<void> route(String type, Route<dynamic>? route) {
    final routeName = route?.settings.name ?? route?.runtimeType.toString();
    final transitionDuration = route is TransitionRoute<dynamic>
        ? route.transitionDuration
        : Duration.zero;

    final updatesRoute =
        type == 'route_push' ||
        type == 'route_replace' ||
        (type == 'route_pop' && route != null) ||
        (type == 'route_remove' && route != null);

    final previousRoute = _currentRoute;
    final destinationRoute = updatesRoute ? routeName : _currentRoute;
    if (type == 'route_push' || type == 'route_replace') {
      _currentRoute = routeName;
    } else if ((type == 'route_pop' || type == 'route_remove') &&
        route != null) {
      _currentRoute = routeName;
    }

    _routeCapturePending = true;
    _skipCapture = transitionDuration > Duration.zero;
    final epoch = ++_routeEpoch;
    final postRouteSettle = _shouldSuppressFrameCapture
        ? Duration.zero
        : config.settleDelay;
    _queue = _queue.then((_) async {
      try {
        await Future<void>.delayed(transitionDuration + postRouteSettle);
        _skipCapture = false;
        if (_disposed) return;
        if (epoch != _routeEpoch) return;
        if (updatesRoute) {
          if (type == 'route_push' || type == 'route_replace') {
            _currentRoute = routeName;
          } else if (route != null) {
            _currentRoute = routeName;
          }
        }
        final isStackCleanupOnly =
            type == 'route_remove' &&
            previousRoute != null &&
            destinationRoute != null &&
            previousRoute == destinationRoute;
        if (isStackCleanupOnly) {
          return;
        }
        _refreshStateAnchor();
        final afterFrame = await _requestCapture(
          trigger: TugboatFrameTrigger.route,
          force: true,
        );
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
              'navigation': type,
            },
          ),
        );
        _maybeEmitSceneInventory();
        if (!_disposed) notifyListeners();
      } finally {
        _routeCapturePending = false;
      }
    });
    return _queue;
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

  void _maybeEmitSceneInventory() {
    if (config.profile == TugboatCaptureProfile.dormant) return;
    final resolver = _anchorResolver;
    if (resolver == null || _session == null) return;

    final inventory = resolver.buildSceneInventory(
      route: _currentRoute,
      keyboardOpen: _isKeyboardOpen(),
      modalOpen: _isModalOpen(),
    );
    if (inventory == null) return;

    _currentStateAnchor = inventory.stateAnchor;
    _emitSceneInventory(inventory);
  }

  void _emitSceneInventory(TugboatSceneInventory inventory) {
    final dedupeKey = '${inventory.stateSignature}|${inventory.inventoryHash}';
    if (!_emittedInventories.add(dedupeKey)) return;

    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'scene_inventory',
        stateAnchor: inventory.stateAnchor,
        data: inventory.toJson(),
      ),
    );
    _maybeEmitViewportSemanticMap(inventory);
  }

  void _maybeEmitViewportSemanticMap(TugboatSceneInventory inventory) {
    if (!_viewportSemanticMapEnabled) return;
    final resolver = _anchorResolver;
    if (resolver == null) return;

    final map = resolver.buildViewportSemanticMap(inventory: inventory);
    if (map == null) return;

    final dedupeKey = '${map.stateSignature}|${map.mapHash}';
    if (!_emittedSemanticMaps.add(dedupeKey)) {
      _latestViewportSemanticMap = map;
      return;
    }

    _latestViewportSemanticMap = map;
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'viewport_semantic_map',
        stateAnchor: map.stateAnchor,
        data: map.toJson(),
      ),
    );
    _logViewportSemanticMapEmit(map);
  }

  TugboatViewportSemanticResolution? _resolveViewportSemanticTap({
    required Offset position,
    TugboatSceneInventory? inventory,
  }) {
    if (!_viewportSemanticMapEnabled) return null;
    final resolver = _anchorResolver;
    final rootRender = _boundaryKey.currentContext?.findRenderObject();
    if (resolver == null || rootRender is! RenderBox) return null;

    if (inventory != null &&
        (_latestViewportSemanticMap == null ||
            _latestViewportSemanticMap!.stateSignature !=
                inventory.stateSignature)) {
      _maybeEmitViewportSemanticMap(inventory);
    }

    final map = _latestViewportSemanticMap;
    if (map == null) {
      return const TugboatViewportSemanticResolution(
        status: 'outside_known_ui',
      );
    }

    return resolver.resolveTapOnViewportSemanticMap(
      tapPosition: position,
      map: map,
      rootRender: rootRender,
    );
  }

  void _logViewportSemanticMapEmit(TugboatViewportSemanticMap map) {
    if (!_viewportSemanticMapDebugLogsEnabled) return;
    debugPrint(
      '[tugboat] viewport_semantic_map route=${map.routeKey} '
      'state=${map.stateSignature} nodes=${map.summary['totalNodes']} '
      'actionable=${map.summary['actionableCount']} '
      'scrollable=${map.summary['scrollableCount']} hash=${map.mapHash}',
    );
  }

  void _logViewportSemanticTapResolution(
    Offset position,
    TugboatViewportSemanticResolution resolution,
  ) {
    if (!_viewportSemanticMapDebugLogsEnabled) return;
    final bounds = resolution.boundsNorm;
    final boundsSummary = bounds == null
        ? 'none'
        : 'l=${bounds.left.toStringAsFixed(3)},'
              't=${bounds.top.toStringAsFixed(3)},'
              'w=${bounds.width.toStringAsFixed(3)},'
              'h=${bounds.height.toStringAsFixed(3)}';
    debugPrint(
      '[tugboat] viewport_semantic_tap '
      'point=(${position.dx.toStringAsFixed(1)},${position.dy.toStringAsFixed(1)}) '
      'status=${resolution.status} role=${resolution.role ?? 'none'} '
      'actions=${resolution.actions.join(',')} bounds=$boundsSummary '
      'fingerprint=${resolution.linkedFingerprint ?? 'none'}',
    );
    if (resolution.status == 'outside_known_ui' ||
        resolution.status == 'matched_non_actionable' ||
        resolution.status == 'matched_disabled') {
      debugPrint(
        '[tugboat] viewport_semantic_anomaly status=${resolution.status} '
        'at=(${position.dx.toStringAsFixed(1)},${position.dy.toStringAsFixed(1)})',
      );
    }
  }

  void _addEvent(TugboatEvent event) {
    final session = _session;
    if (session == null) return;
    final enriched = event.withExplorationContext(
      sessionId: session.id,
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
