import 'dart:async';

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

class PmkitReplayConfig {
  const PmkitReplayConfig({
    this.profile = PmkitCaptureProfile.dormant,
    this.settleDelay = const Duration(seconds: 1),
    this.maxFrames = 500,
    this.maxEvents = 5000,
    this.scrollCaptureInterval = const Duration(seconds: 2),
    this.captureScrollSamples = false,
    this.capturePixelRatio = 0.75,
    this.enableGlobalPointerCapture = true,
    this.explorationCollectorUrl,
    this.explorationRunId,
    this.collector,
    this.screenshotMaskLevel,
    this.widgetNames = const {},
  });

  final PmkitCaptureProfile profile;
  final Duration settleDelay;
  final int maxFrames;
  final int maxEvents;
  final Duration scrollCaptureInterval;
  final bool captureScrollSamples;
  final double capturePixelRatio;
  final bool enableGlobalPointerCapture;
  final String? explorationCollectorUrl;
  final String? explorationRunId;
  final PmkitCollectorConfig? collector;
  final PmkitScreenshotMaskLevel? screenshotMaskLevel;
  final Map<Type, String> widgetNames;

  PmkitScreenshotMaskLevel get effectiveScreenshotMaskLevel =>
      screenshotMaskLevel ??
      switch (profile) {
        PmkitCaptureProfile.productionLean =>
          PmkitScreenshotMaskLevel.allTextAndMedia,
        PmkitCaptureProfile.dormant || PmkitCaptureProfile.exploration =>
          PmkitScreenshotMaskLevel.explicitOnly,
      };

  PmkitReplayConfig copyWith({
    PmkitCaptureProfile? profile,
    Duration? settleDelay,
    int? maxFrames,
    int? maxEvents,
    Duration? scrollCaptureInterval,
    bool? captureScrollSamples,
    double? capturePixelRatio,
    bool? enableGlobalPointerCapture,
    String? explorationCollectorUrl,
    String? explorationRunId,
    PmkitCollectorConfig? collector,
    PmkitScreenshotMaskLevel? screenshotMaskLevel,
    Map<Type, String>? widgetNames,
  }) {
    return PmkitReplayConfig(
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
      collector: collector ?? this.collector,
      screenshotMaskLevel: screenshotMaskLevel ?? this.screenshotMaskLevel,
      widgetNames: widgetNames ?? this.widgetNames,
    );
  }
}

class _ScheduledCapture {
  _ScheduledCapture({
    required this.trigger,
    required this.force,
    required this.notBefore,
  });

  PmkitFrameTrigger trigger;
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

  static int _triggerPriority(PmkitFrameTrigger trigger) {
    switch (trigger) {
      case PmkitFrameTrigger.manual:
        return 6;
      case PmkitFrameTrigger.route:
        return 5;
      case PmkitFrameTrigger.lifecycle:
        return 4;
      case PmkitFrameTrigger.tap:
        return 3;
      case PmkitFrameTrigger.scroll:
        return 2;
      case PmkitFrameTrigger.initial:
        return 1;
    }
  }
}

class PmkitReplayController extends ChangeNotifier {
  PmkitReplayController({required this.config, required GlobalKey boundaryKey})
    : _boundaryKey = boundaryKey;

  final PmkitReplayConfig config;
  final GlobalKey _boundaryKey;

  final Stopwatch _clock = Stopwatch();
  Future<void> _queue = Future.value();

  PmkitSession? _session;
  ScreenshotCapturer? _capturer;
  AnchorResolver? _anchorResolver;
  PmkitCaptureSinkHub? _sinkHub;
  ExplorationCaptureSink? _explorationSink;
  CollectorHttpSink? _collectorHttpSink;
  String? _activeExplorationRunId;
  String? _activeActionId;

  int _id = 0;
  String? _currentRoute;
  PmkitStateAnchor? _currentStateAnchor;
  String? _latestFrameId;
  String? _pendingTapEventId;
  PmkitTargetAnchor? _pendingTapTargetAnchor;
  final Map<String, String> _hashToFrameId = {};

  bool _disposed = false;
  bool _capturePaused = false;
  bool _captureInFlight = false;
  bool _capturePumpScheduled = false;
  bool _scrolling = false;
  bool _skipCapture = false;
  bool _routeCapturePending = false;
  int? _scrollStartedAt;
  double? _scrollStartOffset;
  DateTime? _lastScrollCaptureAt;
  String? _activeScrollBeforeFrame;
  String? _lastCapturedStateSignature;
  String? _lastDHash;

  _ScheduledCapture? _scheduledCapture;

  BuildContext? navigatorContext;

  PmkitSession? get session => _session;
  bool get recording => _session != null;
  bool get scrolling => _scrolling;
  bool get capturePaused => _capturePaused;
  int get atMs => _clock.elapsedMilliseconds;
  String? get currentRoute => _currentRoute;
  PmkitStateAnchor? get currentStateAnchor => _currentStateAnchor;
  String? get latestFrameId => _latestFrameId;

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
    final sinks = <PmkitCaptureSink>[];
    final collectorUrl = config.explorationCollectorUrl;
    if (collectorUrl != null) {
      _explorationSink = ExplorationCaptureSink(
        url: collectorUrl,
        runId: config.explorationRunId,
        onControl: handleExplorationControl,
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
      _sinkHub = PmkitCaptureSinkHub(sinks);
    }
  }

  @override
  void dispose() {
    _disposed = true;
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
    _session = PmkitSession(
      id: 'session-${DateTime.now().microsecondsSinceEpoch}',
      startedAt: DateTime.now(),
      platform: platform,
      viewport: PmkitRect(0, 0, viewport.width, viewport.height),
    );
    _currentRoute = null;
    _currentStateAnchor = null;
    _latestFrameId = null;
    _pendingTapEventId = null;
    _pendingTapTargetAnchor = null;
    _hashToFrameId.clear();
    _lastCapturedStateSignature = null;
    _lastDHash = null;
    if (!_disposed) notifyListeners();
    _sinkHub?.startSession(_session!);
    _addEvent(
      PmkitEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'session_start',
        stateAnchor: _refreshStateAnchor(),
      ),
    );
    unawaited(
      _requestCapture(
        trigger: PmkitFrameTrigger.initial,
        settleDelay: Duration.zero,
      ),
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

  PmkitStateAnchor? _refreshStateAnchor() {
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
    required PmkitFrameTrigger trigger,
    bool force = false,
    Duration? settleDelay,
  }) {
    if (_disposed || _capturePaused || _skipCapture) {
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
    required PmkitFrameTrigger trigger,
    bool force = false,
  }) async {
    if (_disposed || _capturePaused || _skipCapture || _captureInFlight) {
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
        trigger != PmkitFrameTrigger.initial &&
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
        return existingId;
      }

      final frameId = _nextId('frame');
      final frame = PmkitFrame(
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

  void recordPointerDown(Offset position) {
    final resolver = _anchorResolver;
    final target = resolver?.targetAt(position, route: _currentRoute);
    final beforeFrame = _latestFrameId;
    final eventId = _nextId('event');
    _pendingTapEventId = eventId;
    _pendingTapTargetAnchor = target;
    _addEvent(
      PmkitEvent(
        id: eventId,
        atMs: atMs,
        type: 'tap',
        stateAnchor: _currentStateAnchor,
        targetAnchor: target,
        beforeFrame: beforeFrame,
        data: {'x': position.dx, 'y': position.dy},
      ),
    );
    if (!_disposed) notifyListeners();
  }

  void recordPointerUp(Offset position) {
    _queue = _queue.then((_) async {
      if (_disposed) return;
      final beforeState = _currentStateAnchor;
      final beforeFrame = _latestFrameId;
      final tapEventId = _pendingTapEventId;
      final tapTargetAnchor = _pendingTapTargetAnchor;
      _pendingTapEventId = null;
      _pendingTapTargetAnchor = null;

      final String? afterFrame;
      if (_routeCapturePending) {
        afterFrame = _latestFrameId;
      } else {
        _refreshStateAnchor();
        afterFrame = await _requestCapture(trigger: PmkitFrameTrigger.tap);
      }
      final afterState = _currentStateAnchor;

      PmkitInteractionResult result = PmkitInteractionResult.unknown;
      if (afterFrame != null && afterFrame == beforeFrame) {
        result = PmkitInteractionResult.noVisibleChange;
      } else if (beforeState == afterState && beforeFrame == afterFrame) {
        result = PmkitInteractionResult.noVisibleChange;
      } else if (afterFrame != beforeFrame) {
        result = PmkitInteractionResult.changed;
      }

      _addEvent(
        PmkitEvent(
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

  void onScrollActivityChanged({required bool active}) {
    _scrolling = active;
    if (active) {
      _scrollStartedAt = atMs;
      _activeScrollBeforeFrame = _latestFrameId;
    }
  }

  void recordScrollStart(double offset) {
    _scrolling = true;
    _scrollStartedAt = atMs;
    _scrollStartOffset = offset;
    _activeScrollBeforeFrame = _latestFrameId;
    _lastScrollCaptureAt = DateTime.now();
    final session = _session;
    if (session != null) {
      session.scrollSamples.add(
        PmkitScrollSample(
          atMs: atMs,
          offset: offset,
          beforeFrame: _activeScrollBeforeFrame,
        ),
      );
      _trimScrollSamples();
    }
    _addEvent(
      PmkitEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'scroll_start',
        stateAnchor: _currentStateAnchor,
        beforeFrame: _latestFrameId,
        data: {'offset': offset},
      ),
    );
    if (!_disposed) notifyListeners();
  }

  void recordScrollSample(double offset) {
    final session = _session;
    if (session == null || _capturePaused || !_scrolling) return;
    if (!config.captureScrollSamples) return;
    final now = DateTime.now();
    if (_lastScrollCaptureAt != null &&
        now.difference(_lastScrollCaptureAt!) < config.scrollCaptureInterval) {
      return;
    }
    _lastScrollCaptureAt = now;
    session.scrollSamples.add(
      PmkitScrollSample(
        atMs: atMs,
        offset: offset,
        beforeFrame: _activeScrollBeforeFrame,
      ),
    );
    _trimScrollSamples();
    unawaited(_requestCapture(trigger: PmkitFrameTrigger.scroll));
  }

  void recordScrollEnd(double offset) {
    _scrolling = false;
    _queue = _queue.then((_) async {
      final afterFrame = await _requestCapture(
        trigger: PmkitFrameTrigger.scroll,
      );
      if (_session != null && _session!.scrollSamples.isNotEmpty) {
        final last = _session!.scrollSamples.last;
        _session!.scrollSamples[_session!.scrollSamples.length -
            1] = PmkitScrollSample(
          atMs: last.atMs,
          offset: last.offset,
          beforeFrame: last.beforeFrame,
          afterFrame: afterFrame,
        );
      }
      _addEvent(
        PmkitEvent(
          id: _nextId('event'),
          atMs: atMs,
          type: 'scroll_end',
          stateAnchor: _refreshStateAnchor(),
          beforeFrame: _activeScrollBeforeFrame,
          afterFrame: afterFrame,
          data: {
            'startOffset': _scrollStartOffset,
            'endOffset': offset,
            'durationMs': _scrollStartedAt == null
                ? null
                : atMs - _scrollStartedAt!,
          },
        ),
      );
      _scrollStartedAt = null;
      _scrollStartOffset = null;
      _activeScrollBeforeFrame = null;
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
    _queue = _queue.then((_) async {
      try {
        await Future<void>.delayed(transitionDuration + config.settleDelay);
        _skipCapture = false;
        if (_disposed) return;
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
          trigger: PmkitFrameTrigger.route,
          force: true,
        );
        _addEvent(
          PmkitEvent(
            id: _nextId('event'),
            atMs: atMs,
            type: 'route_change',
            stateAnchor: _currentStateAnchor,
            afterFrame: afterFrame,
            result: PmkitInteractionResult.navigated,
            data: {
              if (previousRoute != null) 'fromRoute': previousRoute,
              if (destinationRoute != null) 'route': destinationRoute,
              'navigation': type,
            },
          ),
        );
        if (!_disposed) notifyListeners();
      } finally {
        _routeCapturePending = false;
      }
    });
    return _queue;
  }

  void _maybeEmitStateChange({
    required PmkitStateAnchor? beforeState,
    required PmkitStateAnchor? afterState,
    required String? beforeFrame,
    required String? afterFrame,
  }) {
    final beforeSignature = beforeState?.signature ?? '';
    final afterSignature = afterState?.signature ?? '';
    if (beforeSignature.isEmpty || afterSignature.isEmpty) return;
    if (beforeSignature == afterSignature) return;

    _addEvent(
      PmkitEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'state_change',
        stateAnchor: afterState,
        beforeFrame: beforeFrame,
        afterFrame: afterFrame,
        result: PmkitInteractionResult.changed,
        data: {
          if (afterState?.subLabel != null) 'subLabel': afterState!.subLabel,
        },
      ),
    );
  }

  void _addEvent(PmkitEvent event) {
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
  }

  void clearExplorationActionWindow() {
    _activeActionId = null;
  }

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
