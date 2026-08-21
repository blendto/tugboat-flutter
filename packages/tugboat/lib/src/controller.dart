import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'capture_profile.dart';
import 'capture_sink.dart';
import 'collector_http_sink.dart';
import 'coordinate_space.dart';
import 'debug_logging.dart';
import 'exploration_sink.dart';
import 'evidence_recorder.dart';
import 'external_event.dart';
import 'health.dart';
import 'interaction_transaction.dart';
import 'models.dart';
import 'network_observer.dart';
import 'replay_config.dart';
import 'screenshot_capturer.dart';
import 'screenshot_encode.dart';
import 'viewport_semantic_session.dart';

export 'replay_config.dart'
    show
        TugboatReplayConfig,
        TugboatViewportSemanticMode,
        TugboatViewportSemanticPolicy,
        resolveViewportSemanticPolicy;

class _ScrollTracker {
  _ScrollTracker({
    required this.scrollableElement,
    required this.startEventId,
    required this.startedAtMs,
    required this.startOffset,
    required this.routeEpoch,
    required this.beforeFrame,
    required this.targetAnchor,
    required this.sectionLabel,
    required this.axis,
    required this.depth,
    required this.maxScrollExtent,
    required this.pointerLinked,
    this.pageStart,
  });

  final Element scrollableElement;
  final String startEventId;
  final int startedAtMs;
  final double startOffset;
  final int routeEpoch;
  final String? beforeFrame;
  final TugboatTargetAnchor? targetAnchor;
  final String? sectionLabel;
  final String axis;
  final int depth;
  final double maxScrollExtent;
  final double? pageStart;
  bool pointerLinked;
  int overscrollCount = 0;
  DateTime? lastSampleAt;
  DateTime? lastScreenshotAt;
}

/// Holds the scroll-end work until the matching global pointer-up arrives.
/// Flutter can deliver these callbacks in either order.
class _PendingScrollCompletion {
  _PendingScrollCompletion({
    required this.startOffset,
    required this.endOffset,
    required this.overscrollCount,
    required this.targetAnchor,
  });

  final double startOffset;
  final double endOffset;
  final int overscrollCount;
  final TugboatTargetAnchor? targetAnchor;
  bool resolved = false;
  bool publishing = false;
  String? afterFrame;
  String? captureOutcome;
  _CaptureResolution? captureResolution;

  void applyTo(InteractionTransaction interaction) {
    interaction.scrollStartOffset = startOffset;
    interaction.scrollEndOffset = endOffset;
    interaction.overscrollCount = overscrollCount;
    interaction.scrollTargetAnchor = targetAnchor;
  }
}

class _ScheduledCapture {
  _ScheduledCapture({
    required this.trigger,
    required this.force,
    required this.bypassesExplorationSuppression,
    required this.freshness,
    required this.notBefore,
    required this.enqueuedAt,
    required this.context,
  });

  TugboatFrameTrigger trigger;
  bool force;
  bool bypassesExplorationSuppression;
  _CaptureFreshness freshness;
  DateTime notBefore;
  DateTime enqueuedAt;
  final _CaptureRequestContext context;
  final List<_CaptureWaiter> waiters = [];
  _ScheduledCapture? next;

  void absorb(_ScheduledCapture other) {
    if (_triggerPriority(other.trigger) >= _triggerPriority(trigger)) {
      trigger = other.trigger;
    }
    force = force || other.force;
    bypassesExplorationSuppression =
        bypassesExplorationSuppression || other.bypassesExplorationSuppression;
    if (other.freshness == _CaptureFreshness.freshPaint) {
      freshness = _CaptureFreshness.freshPaint;
    }
    if (other.notBefore.isAfter(notBefore)) {
      notBefore = other.notBefore;
    }
    if (other.enqueuedAt.isBefore(enqueuedAt)) {
      enqueuedAt = other.enqueuedAt;
    }
    for (final waiter in waiters) {
      waiter.coalesced = true;
    }
    for (final waiter in other.waiters) {
      waiter.coalesced = true;
    }
    waiters.addAll(other.waiters);
  }

  bool canAbsorb(_ScheduledCapture other) =>
      trigger != TugboatFrameTrigger.interaction &&
      other.trigger != TugboatFrameTrigger.interaction &&
      context.compatibleWith(other.context);

  static int _triggerPriority(TugboatFrameTrigger trigger) {
    switch (trigger) {
      case TugboatFrameTrigger.manual:
        return 7;
      case TugboatFrameTrigger.interaction:
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

/// The closed, privacy-safe capture result vocabulary.  These are deliberately
/// not exception names: a replay must not expose app content or platform error
/// strings just to explain why a frame was unavailable.
enum _CaptureOutcome {
  freshAccepted,
  exactContentReused,
  perceptualHashCoalesced,
  paintGenerationUnchanged,
  screenshotBudgetSkip,
  capturePressureDrop,
  noFrameAvailable,
  noCompatibleFrame,
  paintReadinessTimeout,
  boundaryUnavailable,
  captureProcessingFailed,
  cancelled,
  supersededRoute,
}

extension on _CaptureOutcome {
  String get wireName => switch (this) {
    _CaptureOutcome.freshAccepted => 'fresh_accepted',
    _CaptureOutcome.exactContentReused => 'exact_content_reused',
    _CaptureOutcome.perceptualHashCoalesced => 'perceptual_hash_coalesced',
    _CaptureOutcome.paintGenerationUnchanged => 'paint_generation_unchanged',
    _CaptureOutcome.screenshotBudgetSkip => 'screenshot_budget_skip',
    _CaptureOutcome.capturePressureDrop => 'capture_pressure_drop',
    _CaptureOutcome.noFrameAvailable => 'no_frame_available',
    _CaptureOutcome.noCompatibleFrame => 'no_compatible_frame',
    _CaptureOutcome.paintReadinessTimeout => 'paint_readiness_timeout',
    _CaptureOutcome.boundaryUnavailable => 'boundary_unavailable',
    _CaptureOutcome.captureProcessingFailed => 'capture_processing_failed',
    _CaptureOutcome.cancelled => 'cancelled',
    _CaptureOutcome.supersededRoute => 'superseded_route_epoch',
  };
}

/// Immutable terminal evidence for one logical request. A coalesced physical
/// capture produces one of these per waiter, preserving each caller's route,
/// trigger, correlation and cancellation reason.
class _CaptureResolution {
  const _CaptureResolution({
    required this.requestId,
    required this.executionId,
    required this.context,
    required this.outcome,
    this.frameId,
    this.failure,
    this.cancellationReason,
    this.reuseReason,
    this.relatedEventId,
    this.coalesced = false,
  });

  final String requestId;
  final String executionId;
  final _CaptureRequestContext context;
  final _CaptureOutcome outcome;
  final String? frameId;
  final ScreenshotCaptureFailure? failure;
  final String? cancellationReason;
  final String? reuseReason;
  final String? relatedEventId;
  final bool coalesced;
}

class _CaptureWaiter {
  _CaptureWaiter({
    required this.requestId,
    required this.context,
    this.relatedEventId,
  });

  final String requestId;
  final _CaptureRequestContext context;
  final String? relatedEventId;
  bool coalesced = false;
  final Completer<_CaptureResolution> completer =
      Completer<_CaptureResolution>();

  bool get isCompleted => completer.isCompleted;
}

class _CaptureExecution {
  const _CaptureExecution({
    required this.outcome,
    this.frameId,
    this.failure,
    this.cancellationReason,
    this.reuseReason,
  });

  final _CaptureOutcome outcome;
  final String? frameId;
  final ScreenshotCaptureFailure? failure;
  final String? cancellationReason;
  final String? reuseReason;
}

enum _CaptureFreshness { reusable, freshPaint }

/// Immutable evidence captured when screenshot work is requested.  A frame is
/// attachable only to requests with the same capture session and route epoch;
/// this prevents a destination tap from inheriting an origin screenshot.
class _CaptureRequestContext {
  const _CaptureRequestContext({
    required this.captureSessionId,
    required this.routeEpoch,
    required this.route,
    required this.trigger,
    required this.requestedAtMs,
    this.navigatorId,
    this.routeInstanceId,
    this.visualObservationGeneration,
    this.boundaryLogicalRect,
    this.boundaryTransformGeneration = 0,
  });

  final String? captureSessionId;
  final int routeEpoch;
  final String? route;
  final TugboatFrameTrigger trigger;
  final int requestedAtMs;
  final String? navigatorId;
  final String? routeInstanceId;
  final int? visualObservationGeneration;
  final Rect? boundaryLogicalRect;
  final int boundaryTransformGeneration;

  bool compatibleWith(_CaptureRequestContext other) =>
      captureSessionId == other.captureSessionId &&
      routeEpoch == other.routeEpoch &&
      route == other.route &&
      navigatorId == other.navigatorId &&
      routeInstanceId == other.routeInstanceId &&
      boundaryTransformGeneration == other.boundaryTransformGeneration;

  bool surfaceCompatibleWith(_CaptureRequestContext other) =>
      captureSessionId == other.captureSessionId &&
      routeEpoch == other.routeEpoch &&
      route == other.route &&
      navigatorId == other.navigatorId &&
      routeInstanceId == other.routeInstanceId;

  _CaptureRequestContext withTrigger(TugboatFrameTrigger value) =>
      _CaptureRequestContext(
        captureSessionId: captureSessionId,
        routeEpoch: routeEpoch,
        route: route,
        trigger: value,
        requestedAtMs: requestedAtMs,
        navigatorId: navigatorId,
        routeInstanceId: routeInstanceId,
        visualObservationGeneration: visualObservationGeneration,
        boundaryLogicalRect: boundaryLogicalRect,
        boundaryTransformGeneration: boundaryTransformGeneration,
      );

  _CaptureRequestContext withBoundaryTransform({
    required Rect logicalRect,
    required int generation,
  }) => _CaptureRequestContext(
    captureSessionId: captureSessionId,
    routeEpoch: routeEpoch,
    route: route,
    trigger: trigger,
    requestedAtMs: requestedAtMs,
    navigatorId: navigatorId,
    routeInstanceId: routeInstanceId,
    visualObservationGeneration: visualObservationGeneration,
    boundaryLogicalRect: logicalRect,
    boundaryTransformGeneration: generation,
  );
}

class _FrameProvenance {
  const _FrameProvenance({
    required this.context,
    required this.completedAtMs,
    required this.sequence,
    this.available = true,
  });

  final _CaptureRequestContext context;
  final int completedAtMs;
  final int sequence;
  final bool available;

  _FrameProvenance unavailable() => _FrameProvenance(
    context: context,
    completedAtMs: completedAtMs,
    sequence: sequence,
    available: false,
  );

  Map<String, Object?> toJson() => {
    'captureSessionId': context.captureSessionId,
    'routeEpoch': context.routeEpoch,
    'route': context.route,
    if (context.navigatorId != null) 'navigatorId': context.navigatorId,
    if (context.routeInstanceId != null)
      'routeInstanceId': context.routeInstanceId,
    if (context.visualObservationGeneration != null)
      'visualObservationGeneration': context.visualObservationGeneration,
    if (context.boundaryLogicalRect != null) ...{
      'boundaryOriginX': context.boundaryLogicalRect!.left,
      'boundaryOriginY': context.boundaryLogicalRect!.top,
      'boundaryWidth': context.boundaryLogicalRect!.width,
      'boundaryHeight': context.boundaryLogicalRect!.height,
    },
    'boundaryTransformGeneration': context.boundaryTransformGeneration,
    'trigger': context.trigger.name,
    'requestedAtMs': context.requestedAtMs,
    'completedAtMs': completedAtMs,
    'sequence': sequence,
    'available': available,
  };
}

class _FrameReuseObservation {
  const _FrameReuseObservation({
    required this.reusedFromFrameId,
    required this.reason,
    required this.reusedAtMs,
  });

  final String reusedFromFrameId;
  final String reason;
  final int reusedAtMs;
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
    this.overlayKind = 'page',
  });

  final _RouteNavigationKind kind;
  final String? routeName;
  final Duration transitionDuration;
  final String overlayKind;
}

/// A resolved, visible navigation: what to record and how to update
/// [TugboatReplayController._currentRoute].
class _VisibleRouteChange {
  const _VisibleRouteChange({
    required this.previousRoute,
    required this.destinationRoute,
    required this.navigation,
    required this.updatesRoute,
    this.navigatorId,
    this.parentNavigatorId,
    this.routeInstanceId,
    this.fromRouteInstanceId,
    this.stackRevision = 0,
    this.overlayKind = 'page',
    this.visualObservationGeneration = 0,
    this.navigationOrigin = 'automatic_or_unknown',
    this.causeEventId,
    this.interactionAttribution,
  });

  final String? previousRoute;
  final String? destinationRoute;
  final String navigation;
  final bool updatesRoute;
  final String? navigatorId;
  final String? parentNavigatorId;
  final String? routeInstanceId;
  final String? fromRouteInstanceId;
  final int stackRevision;
  final String overlayKind;
  final int visualObservationGeneration;
  final String navigationOrigin;
  final String? causeEventId;

  /// Wire form is [InteractionAttribution.claimWireName] (`same_turn` /
  /// `delayed_likely`) when a claim succeeds.
  final InteractionAttribution? interactionAttribution;

  Map<String, Object?> ownershipData() => {
    if (navigatorId != null) 'navigatorId': navigatorId,
    if (parentNavigatorId != null) 'parentNavigatorId': parentNavigatorId,
    if (routeInstanceId != null) 'routeInstanceId': routeInstanceId,
    if (fromRouteInstanceId != null) 'fromRouteInstanceId': fromRouteInstanceId,
    'stackRevision': stackRevision,
    'overlayKind': overlayKind,
    'visualObservationGeneration': visualObservationGeneration,
    'navigationOrigin': navigationOrigin,
    if (causeEventId != null) 'causeEventId': causeEventId,
    if (causeEventId != null) 'causedByInteractionId': causeEventId,
    if (interactionAttribution != null)
      'interactionAttribution': interactionAttribution!.claimWireName,
  };
}

/// Session-local opaque navigator and route-instance ownership.
class _NavigatorSurfaceRegistry {
  final Expando<String> _routeInstanceIds = Expando<String>(
    'tugboat-route-instance',
  );
  final Map<NavigatorState, String> _navigatorIds = <NavigatorState, String>{};
  final Map<String, List<String>> _stacks = <String, List<String>>{};
  final Map<String, String?> _parentByNavigator = <String, String?>{};
  int _navigatorSeq = 0;
  int _routeSeq = 0;

  void clear() {
    _navigatorIds.clear();
    _stacks.clear();
    _parentByNavigator.clear();
    _navigatorSeq = 0;
    _routeSeq = 0;
  }

  String idForNavigator(NavigatorState navigator) {
    return _navigatorIds.putIfAbsent(navigator, () {
      final id = 'nav-$_navigatorSeq';
      _navigatorSeq++;
      _stacks.putIfAbsent(id, () => <String>[]);
      final parentState = _findParentNavigator(navigator);
      _parentByNavigator[id] = parentState == null
          ? null
          : idForNavigator(parentState);
      return id;
    });
  }

  String? parentOf(String navigatorId) => _parentByNavigator[navigatorId];

  String idForRoute(Route<dynamic> route) {
    final existing = _routeInstanceIds[route];
    if (existing != null) return existing;
    final id = 'route-$_routeSeq';
    _routeSeq++;
    _routeInstanceIds[route] = id;
    return id;
  }

  String? peekRouteId(Route<dynamic>? route) =>
      route == null ? null : _routeInstanceIds[route];

  List<String> stackFor(String navigatorId) =>
      _stacks.putIfAbsent(navigatorId, () => <String>[]);

  int push(String navigatorId, String routeInstanceId) {
    final stack = stackFor(navigatorId);
    stack.add(routeInstanceId);
    return stack.length;
  }

  int replaceTop(String navigatorId, String routeInstanceId) {
    final stack = stackFor(navigatorId);
    if (stack.isEmpty) {
      stack.add(routeInstanceId);
    } else {
      stack[stack.length - 1] = routeInstanceId;
    }
    return stack.length;
  }

  int pop(String navigatorId, {String? departingInstanceId}) {
    final stack = stackFor(navigatorId);
    if (departingInstanceId != null) {
      final index = stack.lastIndexOf(departingInstanceId);
      if (index >= 0) {
        stack.removeAt(index);
        return stack.length;
      }
    }
    if (stack.isNotEmpty) stack.removeLast();
    return stack.length;
  }

  String? top(String navigatorId) {
    final stack = stackFor(navigatorId);
    return stack.isEmpty ? null : stack.last;
  }

  static NavigatorState? _findParentNavigator(NavigatorState navigator) {
    NavigatorState? parent;
    navigator.context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is NavigatorState) {
        final state = element.state as NavigatorState;
        if (!identical(state, navigator)) {
          parent = state;
          return false;
        }
      }
      return true;
    });
    return parent;
  }
}

/// The terminal state of a private route-capture barrier.
///
/// This is intentionally not part of the public replay schema. The event
/// writer turns the timeout case into additive `captureOutcome` data.
enum _RouteCaptureOutcome { captured, failed, cancelled, timedOut }

class _RouteCaptureResult {
  const _RouteCaptureResult(
    this.outcome, {
    this.frameId,
    this.routeEventId,
    this.captureFailure,
    this.captureRequestId,
  });

  final _RouteCaptureOutcome outcome;
  final String? frameId;
  final String? routeEventId;
  final String? captureFailure;
  final String? captureRequestId;
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
  void Function(String reason)? _cancelCapture;
  _RouteCaptureWork? supersededBy;

  Future<_RouteCaptureResult> get done => completer.future;

  void attachDeadlineCancellation(void Function() cancelDeadline) {
    if (cancelled) {
      cancelDeadline();
      return;
    }
    _cancelDeadline = cancelDeadline;
  }

  void attachCaptureCancellation(void Function(String reason) cancelCapture) {
    if (cancelled) {
      cancelCapture('manual');
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
  void cancelPendingWork([String reason = 'manual']) {
    _cancelDeadline?.call();
    _cancelDeadline = null;
    _cancelCapture?.call(reason);
    _cancelCapture = null;
  }

  void cancel([String reason = 'manual']) {
    cancelled = true;
    cancelPendingWork(reason);
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
  void Function(String reason)? _cancelCapture;

  void attachCaptureCancellation(void Function(String reason) cancel) {
    if (cancelled) {
      cancel('manual');
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

  void cancel([String reason = 'manual']) {
    cancelled = true;
    _cancelDeadline?.call();
    _cancelDeadline = null;
    _cancelCapture?.call(reason);
    _cancelCapture = null;
    if (!completer.isCompleted) completer.complete();
  }

  void complete() {
    if (!completer.isCompleted) completer.complete();
  }
}

/// The one immutable observation used to write an `interaction` event.
///
/// A tap can outlive both a Navigator callback and another capture request.
/// Do not derive event fields from controller state after this is constructed:
/// that would pair an old frame with a later route/signature.
class _TapSettleObservation {
  const _TapSettleObservation({
    required this.routeEpoch,
    required this.route,
    required this.afterFrame,
    required this.navigationOutcome,
    required this.captureOutcome,
    this.captureFailure,
    this.routeEventId,
    this.captureRequestId,
  });

  final int routeEpoch;
  final String? route;
  final String? afterFrame;
  final String navigationOutcome;
  final String captureOutcome;
  final String? captureFailure;
  final String? routeEventId;
  final String? captureRequestId;

  bool get isDegraded => afterFrame == null && captureOutcome != 'captured';
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
    Map<String, dynamic>? initialTraits,
    String? initialTraitsId,
    String? initialUserId,
    bool initialUserIdOverride = false,
  }) : _boundaryKey = boundaryKey,
       _initialTraits = initialTraits == null
           ? null
           : Map<String, dynamic>.from(initialTraits),
       _initialTraitsId = initialTraitsId,
       _initialUserId = initialUserId,
       _initialUserIdOverride = initialUserIdOverride {
    _evidence = TugboatEvidenceRecorder(
      appendEvidence: (event) => _addEvent(event, attachActionContext: false),
      nextEventId: _nextId,
      nowMs: () => atMs,
      profile: () => config.profile,
    );
  }

  final TugboatReplayConfig config;
  final GlobalKey _boundaryKey;
  late final TugboatEvidenceRecorder _evidence;

  /// Host-supplied activation / request correlation ID (distinct from capture).
  final String? activationRequestId;

  /// Monotonic gate epoch fencing evidence to this capture mount.
  final int sessionEpoch;

  Map<String, dynamic>? _initialTraits;
  final String? _initialTraitsId;
  String? _initialUserId;
  bool _initialUserIdOverride;

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
  final TugboatScreenshotBudgetTracker _screenshotBudget =
      TugboatScreenshotBudgetTracker();
  final List<TugboatSanitizedFailure> _recentFailures = [];
  final List<TugboatCaptureSink> _builtinSinks = [];
  String? _activeExplorationRunId;
  String? _activeActionId;

  int _id = 0;
  String? _currentRoute;
  String? _currentNavigatorId;
  String? _currentRouteInstanceId;
  int _visualObservationGeneration = 0;
  int _boundaryTransformGeneration = 0;
  Rect? _lastObservedBoundaryRect;
  int _pointerGeneration = 0;
  final _NavigatorSurfaceRegistry _surfaces = _NavigatorSurfaceRegistry();
  String? _latestFrameId;
  final InteractionRegistry _interactions = InteractionRegistry();
  bool _reconciliationSweepScheduled = false;
  void Function()? _reconciliationSweepCancel;
  final Map<String, String> _hashToFrameId = {};
  final Map<String, _FrameProvenance> _frameProvenance = {};
  int _frameCompletionSequence = 0;
  final Map<String, _FrameReuseObservation> _frameReuseObservations = {};

  bool _disposed = false;
  bool _capturePaused = false;
  bool _explorationFramesSuppressed = false;
  bool _captureInFlight = false;
  Completer<void> _captureIdle = Completer<void>()..complete();
  int _captureGeneration = 0;
  Completer<void> _captureCancellation = Completer<void>();
  ScreenshotCaptureFailure? _lastCaptureFailure;
  static const int _maxCaptureDiagnosticOutcomes = 16;
  static const int _maxCaptureDiagnosticCount = 10000;
  final Map<String, int> _captureDiagnosticOutcomes = <String, int>{};
  int _captureDiagnosticTotal = 0;
  String? _lastCaptureDiagnosticOutcome;
  bool _capturePumpScheduled = false;
  bool _skipCapture = false;
  bool _captureLifecycleActive = true;
  int _captureLifecycleEpoch = 0;
  int _routeEpoch = 0;
  final Map<String, _RouteCaptureWork> _activeRouteCaptures =
      <String, _RouteCaptureWork>{};
  // A route can finish before its pointer-up settle resumes from the delayed
  // claim wait. Retain that causal barrier until the interaction consumes it.
  final Map<String, _RouteCaptureWork> _causalRouteCaptures =
      <String, _RouteCaptureWork>{};
  final Set<String> _causalRouteSupersededInteractions = <String>{};
  String? _latestRouteCaptureKey;
  final Set<_TapSettleWork> _activeTapSettles = <_TapSettleWork>{};

  /// Most recently started route-capture work (any Navigator).
  _RouteCaptureWork? get _activeRouteCapture {
    final key = _latestRouteCaptureKey;
    if (key == null) return null;
    return _activeRouteCaptures[key];
  }

  static String _routeCaptureKey(String? navigatorId) => navigatorId ?? '';

  final Map<Element, _ScrollTracker> _scrollTrackers = {};
  final Map<String, InteractionTransaction> _scrollInteractions = {};
  final Map<String, _PendingScrollCompletion> _pendingScrollCompletions = {};
  final Map<String, void Function()> _pendingScrollEndDelayCancellations = {};
  final Set<InteractionTransaction> _activeCompletedGestureCaptures = {};
  final Set<Future<void>> _activeCompletedGestureTasks = {};
  final Set<String> _emittedInventories = <String>{};
  SemanticsHandle? _semanticsHandle;
  late final ViewportSemanticSession _viewportSemantics =
      ViewportSemanticSession(
        config: config,
        nextEventId: _nextId,
        atMs: () => atMs,
        addEvent: _addEvent,
      );

  _ScheduledCapture? _scheduledCapture;
  _ScheduledCapture? _activeScheduledCapture;

  BuildContext? navigatorContext;

  TugboatSession? get session => _session;
  bool get recording => _session != null;

  /// Whether the evidence recorder is open for this mounted controller.
  ///
  /// Host apps should gate on [TugboatReplay.isAcceptingEvidence] instead of
  /// reading this directly — the facade also applies lifecycle admission.
  @internal
  bool get acceptingEvidence => !_disposed && _evidence.accepting;

  bool get scrolling => _scrollTrackers.isNotEmpty;
  bool get capturePaused => _capturePaused;
  int get atMs => _clock.elapsedMilliseconds;
  String? get currentRoute => _currentRoute;
  String? get latestFrameId => _latestFrameId;

  bool get _viewportSemanticMapDebugLogsEnabled => _viewportSemantics.debugLogs;

  /// Hold Flutter's SemanticsHandle for the whole session only in exploration.
  /// Production acquires/disposes semantics transiently inside the map builder.
  bool get _holdPersistentSemanticsHandle =>
      _viewportSemantics.holdPersistentSemanticsHandle;

  @visibleForTesting
  void debugSetCurrentRoute(String? route) {
    _currentRoute = route;
  }

  @visibleForTesting
  void debugSetExplorationFramesSuppressed(bool suppressed) {
    _explorationFramesSuppressed = suppressed;
  }

  @visibleForTesting
  int get debugAnchorTokenMapBuildCount =>
      _anchorResolver?.tokenMapBuildCount ?? 0;

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

  /// Optional inline encoder for widget tests that exercise the complete
  /// capture path without a persistent worker isolate.
  @visibleForTesting
  ScreenshotEncoder? debugScreenshotEncoder;

  /// Test-only terminal outcome override for the next physical capture.
  ///
  /// The value must be one of the bounded `capture_diagnostic` outcome names.
  @visibleForTesting
  String? debugNextCaptureOutcome;

  /// Optional compatible frame returned with [debugNextCaptureOutcome].
  @visibleForTesting
  String? debugNextCaptureFrameId;

  /// Deterministically degrades the rolling screenshot budget in tests
  /// without relying on platform readback timing.
  @visibleForTesting
  void debugRecordScreenshotBudgetCost({int costMicros = 1}) {
    _screenshotBudget.record(
      queueWaitMicros: costMicros,
      readbackMicros: 0,
      encodeMicros: 0,
      encodedBytes: 0,
    );
  }

  @visibleForTesting
  ({
    Future<Map<String, Object?>> resolution,
    void Function([String reason]) cancel,
  })
  debugRequestCapture({
    TugboatFrameTrigger trigger = TugboatFrameTrigger.manual,
    bool force = false,
    bool dropWhenBusy = false,
    Duration settleDelay = Duration.zero,
    String? relatedEventId,
  }) {
    final request = _requestCaptureCancellable(
      trigger: trigger,
      force: force,
      dropWhenBusy: dropWhenBusy,
      settleDelay: settleDelay,
      relatedEventId: relatedEventId,
    );
    return (
      resolution: request.resolution.then(
        (value) => <String, Object?>{
          'requestId': value.requestId,
          'executionId': value.executionId,
          'outcome': value.outcome.wireName,
          'frameId': value.frameId,
          'cancellationReason': value.cancellationReason,
          'reuseReason': value.reuseReason,
          'relatedEventId': value.relatedEventId,
          'coalesced': value.coalesced,
        },
      ),
      cancel: request.cancel,
    );
  }

  @visibleForTesting
  int get debugRouteEpoch => _routeEpoch;

  @visibleForTesting
  bool get debugRouteCapturePending => _activeRouteCaptures.isNotEmpty;

  @visibleForTesting
  bool get debugCaptureInFlight => _captureInFlight;

  @visibleForTesting
  String? get debugLastCaptureFailure => _lastCaptureFailure?.name;

  @visibleForTesting
  int get debugActiveTapSettleCount => _activeTapSettles.length;

  @visibleForTesting
  int get debugCausalRouteCaptureCount => _causalRouteCaptures.length;

  @visibleForTesting
  int get debugCausalRouteSupersededInteractionCount =>
      _causalRouteSupersededInteractions.length;

  @visibleForTesting
  List<String?> get debugScheduledCaptureRoutes {
    final routes = <String?>[];
    var scheduled = _scheduledCapture;
    while (scheduled != null) {
      routes.add(scheduled.context.route);
      scheduled = scheduled.next;
    }
    return routes;
  }

  @visibleForTesting
  Map<String, Object?>? debugFrameProvenance(String frameId) {
    final provenance = _frameProvenance[frameId];
    if (provenance == null) return null;
    final reuse = _frameReuseObservations[frameId];
    return {
      ...provenance.toJson(),
      if (reuse != null) ...{
        'reusedFromFrameId': reuse.reusedFromFrameId,
        'reuseReason': reuse.reason,
        'reusedAtMs': reuse.reusedAtMs,
      },
    };
  }

  @visibleForTesting
  int get debugFrameProvenanceCount => _frameProvenance.length;

  @visibleForTesting
  int get debugFrameReuseObservationCount => _frameReuseObservations.length;

  @visibleForTesting
  String? debugReuseFrameForCurrentRoute(
    String frameId, {
    String reason = 'content_hash',
  }) => _reuseCompatibleFrame(
    frameId,
    _captureContext(TugboatFrameTrigger.manual),
    reason,
  );

  @visibleForTesting
  Future<void> drainPointerQueue() async {
    await _queue;
    final settles = _activeTapSettles.toList(growable: false);
    await Future.wait(settles.map((work) => work.completer.future));
    while (_activeCompletedGestureTasks.isNotEmpty) {
      await Future.wait(_activeCompletedGestureTasks.toList(growable: false));
    }
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
    _frameProvenance[frameId] = _FrameProvenance(
      context: _captureContext(trigger),
      completedAtMs: atMs,
      sequence: ++_frameCompletionSequence,
    );
    _capturer?.rememberAcceptedPaintGeneration();
    _trim();
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
  Map<String, Object?> debugExportSemanticSnapshot({Offset? tapPoint}) {
    final resolver = _anchorResolver;
    TugboatTargetAnchor? targetAnchor;
    if (tapPoint != null && resolver != null) {
      targetAnchor = resolver.targetAt(tapPoint, route: _currentRoute);
    }

    return {
      'atMs': atMs,
      'route': _currentRoute,
      'frameId': _compatibleFrameFor(
        _captureContext(TugboatFrameTrigger.manual),
      ),
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
      maxWidth: config.captureMaxWidth,
      maxHeight: config.captureMaxHeight,
      degradedScale: config.degradedCaptureScale,
      maskLevel: config.effectiveScreenshotMaskLevel,
      anchorResolver: resolver,
      encoder: debugScreenshotEncoder,
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
      // [_initialTraits] / [_initialUserId] may have been updated by
      // setTraits/setUserId after construction but before initialize.
      final userId = _initialUserIdOverride
          ? _initialUserId
          : collectorConfig.withUserId(config.userId).userId;
      _collectorHttpSink = CollectorHttpSink(
        config: collectorConfig.withUserId(userId),
        initialTraits: _initialTraits,
        initialTraitsId: _initialTraitsId,
        initialUserId: userId,
      );
      sinks.add(_collectorHttpSink!);
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

  /// See [TugboatReplay.setTraits].
  Future<void> setTraits(Map<String, dynamic> traits) {
    final sink = _collectorHttpSink;
    if (sink != null) return sink.setTraits(traits);
    // Capture can call identify after the controller mounts but before
    // [initialize] builds the HTTP sink — retain for session_start.
    _initialTraits = Map<String, dynamic>.from(traits);
    return Future<void>.value();
  }

  /// See [TugboatReplay.setUserId].
  Future<void> setUserId(String? userId) {
    final sink = _collectorHttpSink;
    if (sink != null) return sink.setUserId(userId);
    _initialUserId = userId;
    _initialUserIdOverride = true;
    return Future<void>.value();
  }

  /// Collector traits id cached on the HTTP sink, if any.
  String? get collectorTraitsId => _collectorHttpSink?.traitsId;

  /// Collector traits bag cached on the HTTP sink, if any.
  Map<String, dynamic>? get collectorTraits => _collectorHttpSink?.traits;

  /// Runtime user id on the HTTP sink, if any.
  String? get collectorUserId => _collectorHttpSink?.userId;

  TugboatSdkHealth healthSnapshot() {
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
      screenshots: _screenshotBudget.snapshot(),
      captureDiagnostics: TugboatCaptureDiagnosticHealth(
        total: _captureDiagnosticTotal,
        lastOutcome: _lastCaptureDiagnosticOutcome,
        outcomes: Map.unmodifiable(_captureDiagnosticOutcomes),
      ),
      evidence: _evidence.healthSnapshot(),
      truncated: _session?.truncated ?? false,
      recentFailures: List.unmodifiable(_recentFailures),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    final hub = _sinkHub;
    final ending = _endSession('dispose');
    _disposed = true;
    _clearReleasedInteractions();
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
    _sinkHub = null;
    _session = null;
    _cancelScheduledCaptureWaiters('dispose');
    if (hub != null) {
      unawaited(ending.whenComplete(hub.dispose));
    }
    _explorationSink = null;
    _collectorHttpSink = null;
    final capturer = _capturer;
    _capturer = null;
    if (capturer != null) {
      unawaited(capturer.dispose());
    }
    super.dispose();
  }

  /// Emits the final timeline event and flushes lifecycle output once.
  Future<void> endSession() {
    return _endSession('session_end');
  }

  Future<void> _endSession(String cancellationReason) {
    final active = _endSessionFuture;
    if (active != null) return active;
    if (_session == null) return Future<void>.value();

    // Claim the end-session future before any sync sink work so re-entry sees
    // a single in-flight end and cannot race a null future.
    final done = Completer<void>();
    _endSessionFuture = done.future;

    // Fence evidence before publishing the terminal event — sink delivery is
    // synchronous and may re-enter the controller.
    _evidence.close();

    _cancelActiveTapSettles(cancellationReason);
    _cancelActiveRouteCapture(cancellationReason);
    _invalidateCaptureWork(cancellationReason);
    // Routes cancelled above never publish causeEventId — do not mint an
    // orphan causal_only tap for a claim that will never be referenced.
    _abandonAllPendingPointers();
    _clearReleasedInteractions();
    _finalizeActiveCompletedGestureCaptures(
      InteractionRejectionReason.sessionEnd,
    );
    _finalizeScrollCompletionInteractions(
      InteractionRejectionReason.sessionEnd,
    );
    _clearScrollCompletionState();
    _captureLifecycleActive = false;

    _addEvent(
      TugboatEvent(id: _nextId('event'), atMs: atMs, type: 'session_end'),
    );
    final sinkEnd = _sinkHub?.endSession() ?? Future<void>.value();
    sinkEnd.then(done.complete, onError: done.completeError);
    return done.future;
  }

  /// Pushes buffered capture output without closing the session.
  Future<void> flushCapture() {
    return _sinkHub?.flush() ?? Future<void>.value();
  }

  void setCapturePaused(bool paused) {
    _capturePaused = paused;
  }

  void start(Size viewport, String platform) {
    _cancelActiveTapSettles('session_replacement');
    _cancelActiveRouteCapture('session_replacement');
    _invalidateCaptureWork('session_replacement');
    _finalizeActiveCompletedGestureCaptures(
      InteractionRejectionReason.sessionEnd,
    );
    _finalizeScrollCompletionInteractions(
      InteractionRejectionReason.sessionEnd,
    );
    _abandonAllPendingPointers(gestureFinal: 'session_end');
    _clearReleasedInteractions(reason: InteractionRejectionReason.sessionEnd);
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
    _currentNavigatorId = null;
    _currentRouteInstanceId = null;
    _visualObservationGeneration = 0;
    _frameCompletionSequence = 0;
    _boundaryTransformGeneration = 0;
    _lastObservedBoundaryRect = null;
    _pointerGeneration = 0;
    _surfaces.clear();
    _latestFrameId = null;
    _interactions.clearAll();
    _clearScrollCompletionState();
    _causalRouteCaptures.clear();
    _causalRouteSupersededInteractions.clear();
    _hashToFrameId.clear();
    _frameProvenance.clear();
    _frameReuseObservations.clear();
    _lastCaptureFailure = null;
    _emittedInventories.clear();
    _viewportSemantics.clear();
    _capturer?.resetCoalesceState();
    _captureDiagnosticOutcomes.clear();
    _captureDiagnosticTotal = 0;
    _lastCaptureDiagnosticOutcome = null;
    _evidence.bindSession(_session!);
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
      TugboatEvent(id: _nextId('event'), atMs: atMs, type: 'session_start'),
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

  _CaptureRequestContext _captureContext(TugboatFrameTrigger trigger) {
    final boundary = _observeCurrentBoundaryTransform();
    return _CaptureRequestContext(
      captureSessionId: _session?.id,
      routeEpoch: _routeEpoch,
      route: _currentRoute,
      trigger: trigger,
      requestedAtMs: atMs,
      navigatorId: _currentNavigatorId,
      routeInstanceId: _currentRouteInstanceId,
      visualObservationGeneration: _visualObservationGeneration,
      boundaryLogicalRect: boundary.rect,
      boundaryTransformGeneration: boundary.generation,
    );
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

  _CaptureFreshness _captureFreshnessFor(
    TugboatFrameTrigger trigger,
    bool force,
  ) {
    if (force ||
        trigger == TugboatFrameTrigger.initial ||
        trigger == TugboatFrameTrigger.lifecycle ||
        trigger == TugboatFrameTrigger.tap ||
        trigger == TugboatFrameTrigger.interaction) {
      return _CaptureFreshness.freshPaint;
    }
    return _CaptureFreshness.reusable;
  }

  ({Rect? rect, int generation}) _observeCurrentBoundaryTransform() {
    final renderObject = _boundaryKey.currentContext?.findRenderObject();
    Rect? rect;
    if (renderObject is RenderBox && renderObject.hasSize) {
      rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    }
    return _observeBoundaryTransform(rect);
  }

  ({Rect? rect, int generation}) _observeBoundaryTransform(Rect? rect) {
    if (rect != null && !_sameBoundaryRect(_lastObservedBoundaryRect, rect)) {
      if (_lastObservedBoundaryRect != null) {
        _boundaryTransformGeneration++;
      }
      _lastObservedBoundaryRect = rect;
    }
    return (rect: rect, generation: _boundaryTransformGeneration);
  }

  bool _sameBoundaryRect(Rect? left, Rect right) {
    if (left == null) return false;
    const epsilon = 0.01;
    return (left.left - right.left).abs() <= epsilon &&
        (left.top - right.top).abs() <= epsilon &&
        (left.width - right.width).abs() <= epsilon &&
        (left.height - right.height).abs() <= epsilon;
  }

  String? _compatibleFrameFor(_CaptureRequestContext context) {
    final latest = _latestFrameId;
    if (latest == null) return null;
    final provenance = _frameProvenance[latest];
    if (provenance == null || !provenance.available) return null;
    return provenance.context.compatibleWith(context) ? latest : null;
  }

  String? _surfaceCompatibleFrameFor(_CaptureRequestContext context) {
    final latest = _latestFrameId;
    if (latest == null) return null;
    final provenance = _frameProvenance[latest];
    if (provenance == null || !provenance.available) return null;
    return provenance.context.surfaceCompatibleWith(context) ? latest : null;
  }

  String? _unavailableAttachmentReason(_CaptureRequestContext context) {
    if (_compatibleFrameFor(context) != null) return null;
    return _latestFrameId == null
        ? 'no_frame_available'
        : 'no_compatible_frame';
  }

  bool _isFrameCompatible(String frameId, _CaptureRequestContext context) {
    final provenance = _frameProvenance[frameId];
    return provenance != null &&
        provenance.available &&
        provenance.context.compatibleWith(context);
  }

  String? _reuseCompatibleFrame(
    String frameId,
    _CaptureRequestContext context,
    String reason,
  ) {
    if (!_isFrameCompatible(frameId, context)) return null;
    _latestFrameId = frameId;
    _frameReuseObservations[frameId] = _FrameReuseObservation(
      reusedFromFrameId: frameId,
      reason: reason,
      reusedAtMs: atMs,
    );
    return frameId;
  }

  _CaptureExecution _reuseWithoutCapture({
    required _CaptureRequestContext context,
    required _CaptureOutcome outcome,
    required String reuseReason,
    int queueWaitMicros = 0,
    bool recordBudget = false,
    String? budgetDropReason,
  }) {
    final compatible = _compatibleFrameFor(context);
    if (compatible == null) {
      return const _CaptureExecution(
        outcome: _CaptureOutcome.noCompatibleFrame,
      );
    }
    if (recordBudget) {
      _screenshotBudget.record(
        queueWaitMicros: queueWaitMicros,
        readbackMicros: 0,
        encodeMicros: 0,
        encodedBytes: 0,
        dropReason: budgetDropReason ?? reuseReason,
      );
    }
    _reuseCompatibleFrame(compatible, context, reuseReason);
    _maybeEmitSceneInventory();
    return _CaptureExecution(
      outcome: outcome,
      frameId: compatible,
      reuseReason: reuseReason,
    );
  }

  /// Emits exactly one bounded, sanitized resolution record for a logical
  /// request. This deliberately records a taxonomy value rather than the
  /// underlying exception so replay telemetry never contains app data.
  ///
  /// [productionLean] profiles update [healthSnapshot] counters only. Session
  /// and collector output omit `capture_diagnostic` events to reduce volume.
  void _recordCaptureDiagnostic(_CaptureResolution resolution) {
    final outcome = resolution.outcome.wireName;
    _captureDiagnosticTotal = (_captureDiagnosticTotal + 1).clamp(
      0,
      _maxCaptureDiagnosticCount,
    );
    _lastCaptureDiagnosticOutcome = outcome;
    if (_captureDiagnosticOutcomes.containsKey(outcome) ||
        _captureDiagnosticOutcomes.length < _maxCaptureDiagnosticOutcomes) {
      _captureDiagnosticOutcomes[outcome] =
          ((_captureDiagnosticOutcomes[outcome] ?? 0) + 1).clamp(
            0,
            _maxCaptureDiagnosticCount,
          );
    }
    if (config.profile == TugboatCaptureProfile.productionLean) return;
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'capture_diagnostic',
        stream: TugboatEventStream.diagnostic,
        afterFrame: resolution.frameId,
        data: <String, Object?>{
          'version': 1,
          'outcome': outcome,
          'requestId': resolution.requestId,
          'executionId': resolution.executionId,
          'captureSessionId': resolution.context.captureSessionId,
          'routeEpoch': resolution.context.routeEpoch,
          if (resolution.context.navigatorId != null)
            'navigatorId': resolution.context.navigatorId,
          if (resolution.context.routeInstanceId != null)
            'routeInstanceId': resolution.context.routeInstanceId,
          'trigger': resolution.context.trigger.name,
          'visualEvidence': resolution.frameId == null
              ? 'unavailable'
              : resolution.outcome == _CaptureOutcome.freshAccepted
              ? 'fresh'
              : 'reused',
          'interactionEvidence': resolution.relatedEventId == null
              ? 'not_applicable'
              : 'linked',
          if (resolution.relatedEventId != null)
            'relatedEventId': resolution.relatedEventId,
          if (resolution.cancellationReason != null)
            'cancellationReason': resolution.cancellationReason,
          if (resolution.reuseReason != null)
            'reuseReason': resolution.reuseReason,
          if (resolution.coalesced) 'coalesced': true,
        },
      ),
    );
  }

  _CaptureOutcome _diagnosticOutcomeForFailure(
    ScreenshotCaptureFailure? failure,
  ) {
    switch (failure) {
      case ScreenshotCaptureFailure.paintTimedOut:
      case ScreenshotCaptureFailure.paintNotAdvanced:
        return _CaptureOutcome.paintReadinessTimeout;
      case ScreenshotCaptureFailure.boundaryDetached:
      case ScreenshotCaptureFailure.boundaryUnavailable:
      case ScreenshotCaptureFailure.boundaryReplaced:
      case ScreenshotCaptureFailure.layoutUnavailable:
        return _CaptureOutcome.boundaryUnavailable;
      case ScreenshotCaptureFailure.readbackFailed:
      case ScreenshotCaptureFailure.maskFailed:
      case ScreenshotCaptureFailure.encodingFailed:
        return _CaptureOutcome.captureProcessingFailed;
      case ScreenshotCaptureFailure.cancelled:
        return _CaptureOutcome.cancelled;
      case null:
        return _CaptureOutcome.noFrameAvailable;
    }
  }

  _CaptureExecution _cancelledCaptureExecution(String reason) {
    const allowedReasons = <String>{
      'manual',
      'dispose',
      'session_end',
      'session_replacement',
      'lifecycle_deactivate',
      'superseded_route',
      'route_timeout',
      'capture_paused',
      'route_transition',
      'capture_suppressed',
      'capture_in_flight',
      'capture_pressure',
      'debug',
    };
    final sanitizedReason = allowedReasons.contains(reason) ? reason : 'manual';
    return _CaptureExecution(
      outcome: sanitizedReason == 'superseded_route'
          ? _CaptureOutcome.supersededRoute
          : _CaptureOutcome.cancelled,
      cancellationReason: sanitizedReason,
    );
  }

  String _captureSuppressionReason() {
    if (_disposed) return 'dispose';
    if (_capturePaused) return 'capture_paused';
    if (_skipCapture) return 'route_transition';
    return 'capture_suppressed';
  }

  bool _captureContextStillCurrent(
    _CaptureRequestContext context,
    int generation,
    TugboatSession? session,
  ) {
    final boundary = _observeCurrentBoundaryTransform();
    return !_disposed &&
        generation == _captureGeneration &&
        identical(_session, session) &&
        context.captureSessionId == session?.id &&
        context.routeEpoch == _routeEpoch &&
        context.route == _currentRoute &&
        context.boundaryTransformGeneration == boundary.generation;
  }

  ({
    Future<String?> done,
    Future<_CaptureResolution> resolution,
    void Function([String reason]) cancel,
  })
  _requestCaptureCancellable({
    required TugboatFrameTrigger trigger,
    bool force = false,
    bool bypassExplorationSuppression = false,
    bool dropWhenBusy = false,
    Duration? settleDelay,
    String? relatedEventId,
  }) {
    final context = _captureContext(trigger);
    final waiter = _CaptureWaiter(
      requestId: _nextId('capture_request'),
      context: context,
      relatedEventId: relatedEventId,
    );
    final freshness = _captureFreshnessFor(trigger, force);
    final bypassesExplorationSuppression =
        bypassExplorationSuppression ||
        trigger == TugboatFrameTrigger.interaction;
    if (_disposed ||
        _capturePaused ||
        _skipCapture ||
        (_shouldSuppressFrameCapture && !bypassesExplorationSuppression)) {
      _maybeEmitSceneInventory();
      _completeCaptureWaiter(
        waiter,
        executionId: _nextId('capture_execution'),
        execution: _cancelledCaptureExecution(_captureSuppressionReason()),
      );
      return (
        done: waiter.completer.future.then((value) => value.frameId),
        resolution: waiter.completer.future,
        cancel: ([String reason = 'manual']) {},
      );
    }

    if (dropWhenBusy && (_captureInFlight || _scheduledCapture != null)) {
      _screenshotBudget.record(
        queueWaitMicros: 0,
        readbackMicros: 0,
        encodeMicros: 0,
        encodedBytes: 0,
        dropReason: 'capture_pressure',
      );
      _completeCaptureWaiter(
        waiter,
        executionId: _nextId('capture_execution'),
        execution: const _CaptureExecution(
          outcome: _CaptureOutcome.capturePressureDrop,
          cancellationReason: 'capture_pressure',
        ),
      );
      return (
        done: waiter.completer.future.then((value) => value.frameId),
        resolution: waiter.completer.future,
        cancel: ([String reason = 'manual']) {},
      );
    }

    final now = _now();
    final delay = settleDelay ?? config.settleDelay;
    final notBefore = now.add(delay);
    final incoming = _ScheduledCapture(
      trigger: trigger,
      force: force,
      bypassesExplorationSuppression: bypassesExplorationSuppression,
      freshness: freshness,
      notBefore: notBefore,
      enqueuedAt: now,
      context: context,
    )..waiters.add(waiter);

    final scheduled = _scheduledCapture;
    if (scheduled == null) {
      _scheduledCapture = incoming;
    } else {
      var tail = scheduled;
      while (tail.next != null) {
        tail = tail.next!;
      }
      // Only adjacent compatible work can coalesce: preserving order prevents
      // an incompatible route capture from being silently dropped.
      if (tail.canAbsorb(incoming)) {
        tail.absorb(incoming);
      } else {
        tail.next = incoming;
      }
    }

    _ensureCapturePumpScheduled();
    return (
      done: waiter.completer.future.then((value) => value.frameId),
      resolution: waiter.completer.future,
      cancel: ([String reason = 'manual']) {
        var scheduled = _scheduledCapture;
        _ScheduledCapture? previous;
        while (scheduled != null) {
          scheduled.waiters.remove(waiter);
          final next = scheduled.next;
          if (scheduled.waiters.isEmpty) {
            if (previous == null) {
              _scheduledCapture = next;
            } else {
              previous.next = next;
            }
          } else {
            previous = scheduled;
          }
          scheduled = next;
        }
        _activeScheduledCapture?.waiters.remove(waiter);
        _completeCaptureWaiter(
          waiter,
          executionId: _nextId('capture_execution'),
          execution: _cancelledCaptureExecution(reason),
        );
      },
    );
  }

  void _completeCaptureWaiter(
    _CaptureWaiter waiter, {
    required String executionId,
    required _CaptureExecution execution,
  }) {
    if (waiter.isCompleted) return;
    final resolution = _CaptureResolution(
      requestId: waiter.requestId,
      executionId: executionId,
      context: waiter.context,
      outcome: execution.outcome,
      frameId: execution.frameId,
      failure: execution.failure,
      cancellationReason: execution.cancellationReason,
      reuseReason: execution.reuseReason,
      relatedEventId: waiter.relatedEventId,
      coalesced: waiter.coalesced,
    );
    waiter.completer.complete(resolution);
    _recordCaptureDiagnostic(resolution);
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

      final queueWaitMicros = _now()
          .difference(scheduled.enqueuedAt)
          .inMicroseconds;
      _scheduledCapture = scheduled.next;
      scheduled.next = null;
      _activeScheduledCapture = scheduled;
      _CaptureExecution execution = const _CaptureExecution(
        outcome: _CaptureOutcome.captureProcessingFailed,
      );
      final executionId = _nextId('capture_execution');
      try {
        execution = await _executeCapture(
          trigger: scheduled.trigger,
          force: scheduled.force,
          bypassExplorationSuppression:
              scheduled.bypassesExplorationSuppression,
          freshness: scheduled.freshness,
          context: scheduled.context.withTrigger(scheduled.trigger),
          queueWaitMicros: queueWaitMicros,
        );
      } catch (error, stackTrace) {
        // A capture failure must not kill the pump loop or strand waiters:
        // stranded waiters would freeze the controller queue permanently.
        debugPrint('[tugboat] capture failed: $error\n$stackTrace');
        execution = const _CaptureExecution(
          outcome: _CaptureOutcome.captureProcessingFailed,
        );
      }
      for (final waiter in scheduled.waiters) {
        final frameId = execution.frameId;
        final compatible =
            frameId != null && _isFrameCompatible(frameId, waiter.context);
        _completeCaptureWaiter(
          waiter,
          executionId: executionId,
          execution: _CaptureExecution(
            outcome: compatible
                ? execution.outcome
                : (execution.frameId == null
                      ? execution.outcome
                      : (_unavailableAttachmentReason(waiter.context) ==
                                'no_frame_available'
                            ? _CaptureOutcome.noFrameAvailable
                            : _CaptureOutcome.noCompatibleFrame)),
            frameId: compatible ? frameId : null,
            failure: execution.failure,
            cancellationReason: execution.cancellationReason,
            reuseReason: execution.reuseReason,
          ),
        );
      }
      if (identical(_activeScheduledCapture, scheduled)) {
        _activeScheduledCapture = null;
      }
    }
  }

  Future<void> _waitForCaptureIdle() async {
    if (_captureInFlight && !_disposed) await _captureIdle.future;
  }

  void _beginCapture() {
    _captureInFlight = true;
    _captureIdle = Completer<void>();
  }

  void _endCapture() {
    _captureInFlight = false;
    if (!_captureIdle.isCompleted) _captureIdle.complete();
  }

  void _cancelScheduledCaptureWaiters([String reason = 'session_replacement']) {
    var scheduled = _scheduledCapture;
    _scheduledCapture = null;
    final active = _activeScheduledCapture;
    if (active != null) {
      for (final waiter in active.waiters.toList(growable: false)) {
        _completeCaptureWaiter(
          waiter,
          executionId: _nextId('capture_execution'),
          execution: _cancelledCaptureExecution(reason),
        );
      }
      active.waiters.clear();
    }
    while (scheduled != null) {
      for (final waiter in scheduled.waiters) {
        _completeCaptureWaiter(
          waiter,
          executionId: _nextId('capture_execution'),
          execution: _cancelledCaptureExecution(reason),
        );
      }
      scheduled = scheduled.next;
    }
  }

  void _invalidateCaptureWork([String reason = 'session_replacement']) {
    _advanceCaptureGeneration();
    _captureLifecycleEpoch++;
    _cancelScheduledCaptureWaiters(reason);
  }

  void _advanceCaptureGeneration() {
    _captureGeneration++;
    if (!_captureCancellation.isCompleted) {
      _captureCancellation.complete();
    }
    _captureCancellation = Completer<void>();
  }

  Future<_CaptureExecution> _executeCapture({
    required TugboatFrameTrigger trigger,
    bool force = false,
    bool bypassExplorationSuppression = false,
    required _CaptureFreshness freshness,
    required _CaptureRequestContext context,
    required int queueWaitMicros,
  }) async {
    final captureGeneration = _captureGeneration;
    final captureCancellation = _captureCancellation.future;
    final captureSession = _session;
    final requiresFreshPaint = freshness == _CaptureFreshness.freshPaint;
    final debugOutcome = debugNextCaptureOutcome;
    if (debugOutcome != null) {
      debugNextCaptureOutcome = null;
      final debugFrameId = debugNextCaptureFrameId;
      debugNextCaptureFrameId = null;
      final outcome = _CaptureOutcome.values.firstWhere(
        (candidate) => candidate.wireName == debugOutcome,
        orElse: () => throw ArgumentError.value(
          debugOutcome,
          'debugNextCaptureOutcome',
          'unsupported capture outcome',
        ),
      );
      return _CaptureExecution(
        outcome: outcome,
        frameId: debugFrameId,
        cancellationReason: outcome == _CaptureOutcome.cancelled
            ? 'debug'
            : null,
        reuseReason: outcome == _CaptureOutcome.exactContentReused
            ? 'content_hash'
            : outcome == _CaptureOutcome.perceptualHashCoalesced
            ? 'dhash'
            : outcome == _CaptureOutcome.paintGenerationUnchanged
            ? 'paint_generation'
            : null,
      );
    }
    if (_disposed ||
        _capturePaused ||
        _skipCapture ||
        (_shouldSuppressFrameCapture && !bypassExplorationSuppression) ||
        _captureInFlight) {
      return _cancelledCaptureExecution(
        _captureInFlight ? 'capture_in_flight' : _captureSuppressionReason(),
      );
    }
    final session = captureSession;
    final capturer = _capturer;
    if (session == null || capturer == null) {
      return const _CaptureExecution(outcome: _CaptureOutcome.noFrameAvailable);
    }

    final compatibleFrame = _compatibleFrameFor(context);
    final hasCompatibleFrame = compatibleFrame != null;

    final eligibleToSkip =
        freshness == _CaptureFreshness.reusable &&
        trigger != TugboatFrameTrigger.initial &&
        trigger != TugboatFrameTrigger.lifecycle &&
        config.screenshotBudget.skipEligibleWhenDegraded &&
        _screenshotBudget.shouldSkipEligible;
    if (eligibleToSkip && hasCompatibleFrame) {
      return _reuseWithoutCapture(
        context: context,
        outcome: _CaptureOutcome.screenshotBudgetSkip,
        reuseReason: 'budget',
        queueWaitMicros: queueWaitMicros,
        recordBudget: true,
        budgetDropReason: 'budget',
      );
    }

    final captureOverride = debugExecuteCapture;
    if (captureOverride != null) {
      _beginCapture();
      try {
        final frameId = await captureOverride(trigger: trigger, force: force);
        if (!_captureContextStillCurrent(
          context,
          captureGeneration,
          captureSession,
        )) {
          return const _CaptureExecution(
            outcome: _CaptureOutcome.supersededRoute,
          );
        }
        if (frameId != null && _frameProvenance.containsKey(frameId)) {
          _latestFrameId = frameId;
        }
        _maybeEmitSceneInventory();
        final resolved = frameId != null && _isFrameCompatible(frameId, context)
            ? frameId
            : (requiresFreshPaint ? null : _compatibleFrameFor(context));
        return _CaptureExecution(
          outcome: resolved == null
              ? (_unavailableAttachmentReason(context) == 'no_frame_available'
                    ? _CaptureOutcome.noFrameAvailable
                    : _CaptureOutcome.noCompatibleFrame)
              : _CaptureOutcome.freshAccepted,
          frameId: resolved,
        );
      } finally {
        _endCapture();
        if (_scheduledCapture != null) {
          _ensureCapturePumpScheduled();
        }
      }
    }

    _beginCapture();
    try {
      var allowPaintSkip =
          trigger != TugboatFrameTrigger.initial && hasCompatibleFrame;
      var captureForce = force || requiresFreshPaint || !hasCompatibleFrame;
      late ScreenshotCaptureAttempt attempt;
      late ScreenshotCaptureResult result;

      for (var paintRetry = 0; paintRetry < 2; paintRetry++) {
        attempt = await capturer.captureAttempt(
          // A freshness-sensitive request needs a new logical observation even
          // when its pixels match. Reusing the old frame would also reuse its
          // old completion-state provenance.
          force: captureForce,
          waitForFrame: true,
          requireFreshPaint: requiresFreshPaint,
          allowPaintGenerationSkip: allowPaintSkip,
          degraded: _screenshotBudget.shouldSkipEligible,
          cancelled: captureCancellation,
          isCurrent: () =>
              _captureContextStillCurrent(
                context,
                captureGeneration,
                captureSession,
              ) &&
              !_capturePaused &&
              !_skipCapture,
        );
        final attemptResult = attempt.result;
        if (attemptResult == null ||
            _disposed ||
            !_captureContextStillCurrent(context, captureGeneration, session)) {
          _lastCaptureFailure = attempt.failure;
          if (attempt.failure != ScreenshotCaptureFailure.cancelled &&
              _captureContextStillCurrent(
                context,
                captureGeneration,
                captureSession,
              )) {
            _screenshotBudget.record(
              queueWaitMicros: queueWaitMicros,
              frameWaitMicros: attempt.frameWaitMicros,
              readbackMicros: 0,
              encodeMicros: 0,
              encodedBytes: 0,
              dropReason: attempt.failure?.name ?? 'capture_failed',
            );
          }
          return _CaptureExecution(
            outcome:
                !_captureContextStillCurrent(
                  context,
                  captureGeneration,
                  captureSession,
                )
                ? _CaptureOutcome.supersededRoute
                : _diagnosticOutcomeForFailure(attempt.failure),
            failure: attempt.failure,
            cancellationReason:
                attempt.failure == ScreenshotCaptureFailure.cancelled
                ? 'superseded_route'
                : null,
          );
        }
        _lastCaptureFailure = null;

        if (attemptResult.skippedByPaintGeneration) {
          final reuseExecution = _reuseWithoutCapture(
            context: context,
            outcome: _CaptureOutcome.paintGenerationUnchanged,
            reuseReason: 'paint_generation',
          );
          if (reuseExecution.outcome == _CaptureOutcome.noCompatibleFrame &&
              paintRetry == 0) {
            allowPaintSkip = false;
            captureForce = true;
            continue;
          }
          return reuseExecution;
        }

        result = attemptResult;
        break;
      }

      final activeSession = session;

      _screenshotBudget.record(
        queueWaitMicros: queueWaitMicros,
        frameWaitMicros: attempt.frameWaitMicros,
        readbackMicros: result.captureMicros,
        maskMicros: result.maskMicros,
        encodeMicros: result.encodeMicros,
        encodedBytes: result.bytes.length,
        coalescedCapture: result.skippedByDHash,
      );

      if (result.skippedByDHash) {
        final compatible = _compatibleFrameFor(context);
        final reused = compatible == null
            ? null
            : _reuseCompatibleFrame(compatible, context, 'dhash');
        if (reused != null) {
          capturer.commitAcceptedPaintGeneration(result.paintGeneration);
          capturer.commitAcceptedDHash(result.dHash);
        }
        return _CaptureExecution(
          outcome: reused == null
              ? _CaptureOutcome.noCompatibleFrame
              : _CaptureOutcome.perceptualHashCoalesced,
          frameId: reused,
          reuseReason: reused == null ? null : 'dhash',
        );
      }

      final existingId = _hashToFrameId[result.contentHash];
      if (!force &&
          !requiresFreshPaint &&
          existingId != null &&
          _isFrameCompatible(existingId, context)) {
        _reuseCompatibleFrame(existingId, context, 'content_hash');
        capturer.commitAcceptedPaintGeneration(result.paintGeneration);
        capturer.commitAcceptedDHash(result.dHash);
        _maybeEmitSceneInventory();
        return _CaptureExecution(
          outcome: _CaptureOutcome.exactContentReused,
          frameId: existingId,
          reuseReason: 'content_hash',
        );
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
        captureMicros:
            attempt.frameWaitMicros +
            result.captureMicros +
            result.maskMicros +
            result.encodeMicros,
        captureSessionId: activeSession.id,
      );
      activeSession.frames.add(frame);
      activeSession.frameBytes[frameId] = result.bytes;
      _hashToFrameId[result.contentHash] = frameId;
      _latestFrameId = frameId;
      final boundary = _observeBoundaryTransform(result.boundaryLogicalRect);
      final frameContext = context.withBoundaryTransform(
        logicalRect: result.boundaryLogicalRect,
        generation: boundary.generation,
      );
      _frameProvenance[frameId] = _FrameProvenance(
        context: frameContext,
        completedAtMs: atMs,
        sequence: ++_frameCompletionSequence,
      );
      capturer.commitAcceptedPaintGeneration(result.paintGeneration);
      capturer.commitAcceptedDHash(result.dHash);
      _maybeEmitSceneInventory();
      _sinkHub?.recordFrame(
        frame,
        result.bytes,
        sessionId: activeSession.id,
        actionId: _activeActionId,
      );
      _trim();
      if (!_disposed) notifyListeners();
      return _CaptureExecution(
        outcome: _CaptureOutcome.freshAccepted,
        frameId: frameId,
      );
    } finally {
      _endCapture();
      if (_scheduledCapture != null) {
        _ensureCapturePumpScheduled();
      }
    }
  }

  bool get _acceptsPointerInput =>
      !_disposed &&
      _session != null &&
      _captureLifecycleActive &&
      _endSessionFuture == null;

  void recordPointerDown(Offset position, {int pointer = 0}) {
    if (!_acceptsPointerInput) return;
    // This is deliberately the first stateful operation. A new gesture makes
    // an idle scroll frame stale, and cancelling it here keeps the next scroll
    // responsive even when Flutter has not yet delivered ScrollStart.
    _cancelDeferredScrollEndCaptures('superseded_by_pointer');
    final previousClaim = _interactions.removeReleased(pointer);
    if (previousClaim != null) {
      _finalizeAbandonedTransaction(
        previousClaim,
        reason: InteractionRejectionReason.claimConsumed,
      );
    }
    if (_interactions.pendingAt(pointer) != null) {
      _abandonPendingPointer(pointer, gestureFinal: 'superseded');
    }
    final isPrimaryPointer = _interactions.pending.isEmpty;
    final attachmentContext = _captureContext(TugboatFrameTrigger.tap);
    final beforeFrame = _compatibleFrameFor(attachmentContext);
    final coordinateFrame =
        beforeFrame ?? _surfaceCompatibleFrameFor(attachmentContext);
    final captureCoordinate = _sampleCaptureCoordinate(
      position: position,
      frameId: coordinateFrame,
      context: attachmentContext,
    );
    final eventId = _nextId('event');
    final startedAtMs = atMs;
    final origin = InteractionOrigin(
      interactionId: eventId,
      route: _currentRoute,
      routeEpoch: _routeEpoch,
      routeInstanceId: _currentRouteInstanceId,
      navigatorId: _currentNavigatorId,
      targetAnchor: null,
      captureCoordinate: captureCoordinate,
      beforeFrame: beforeFrame,
      atMs: startedAtMs,
      startPosition: position,
      pointerGeneration: ++_pointerGeneration,
      captureSessionId: _session?.id,
      explorationRunId: _activeExplorationRunId ?? config.explorationRunId,
      actionId: _activeActionId,
    );
    final tx = InteractionTransaction(origin: origin, pointerId: pointer);
    _interactions.register(tx);
    if (config.profile == TugboatCaptureProfile.exploration &&
        isPrimaryPointer) {
      _captureExplorationPreTapEvidence(tx);
    }
    if (!_disposed) notifyListeners();
  }

  void _captureExplorationPreTapEvidence(InteractionTransaction tx) {
    final stopwatch = Stopwatch()..start();
    TugboatSceneInventory? inventory;
    TugboatTargetAnchor? target;
    TugboatViewportTapSnapshot? semanticSnapshot;
    TugboatTargetResolutionFailureReason? failureReason;

    try {
      final resolver = _anchorResolver;
      final rootRender = _boundaryKey.currentContext?.findRenderObject();
      if (resolver == null || rootRender is! RenderBox || !rootRender.hasSize) {
        failureReason = TugboatTargetResolutionFailureReason.resolutionError;
      } else {
        final localPoint = rootRender.globalToLocal(tx.origin.startPosition);
        final boundary = Offset.zero & rootRender.size;
        if (!boundary.contains(localPoint)) {
          failureReason =
              TugboatTargetResolutionFailureReason.outsideCaptureBoundary;
        } else {
          // Exploration accepts one synchronous rebuild for the primary
          // pointer so delayed same-route state cannot reuse an old token map.
          resolver.invalidateTokenMapCache();
          final tapContext = resolver.buildTapContext(
            tapPosition: tx.origin.startPosition,
            route: tx.origin.route,
            keyboardOpen: _isKeyboardOpen(),
            modalOpen: _isModalOpen(),
          );
          final rawTarget = tapContext.target;
          inventory = _sanitizeExplorationInventory(
            tapContext.inventory,
            rawTargetFingerprint: rawTarget?.fingerprint,
            retainBlockingOverlayTarget:
                tapContext.tapHitsDismissibleBarrier &&
                !_isOpaquePlatformTarget(rawTarget),
          );
          if (inventory == null) {
            failureReason = _isOpaquePlatformTarget(rawTarget)
                ? TugboatTargetResolutionFailureReason.opaquePlatformView
                : TugboatTargetResolutionFailureReason.noSceneInventory;
          } else {
            semanticSnapshot = _viewportSemantics.captureTapSnapshot(
              position: tx.origin.startPosition,
              resolver: resolver,
              boundaryKey: _boundaryKey,
              inventory: inventory,
            );
            target = _selectExplorationTapTarget(
              rawTarget: rawTarget,
              inventory: inventory,
              semanticResolution: semanticSnapshot.resolution,
              allowDismissibleBarrierTarget:
                  tapContext.tapHitsDismissibleBarrier &&
                  !_isOpaquePlatformTarget(rawTarget),
            );
            if (target == null) {
              failureReason = _targetFailureReason(
                rawTarget: rawTarget,
                semanticResolution: semanticSnapshot.resolution,
              );
            }
          }
        }
      }
    } catch (error, stackTrace) {
      failureReason = TugboatTargetResolutionFailureReason.resolutionError;
      debugPrint(
        '[tugboat] exploration pre-tap resolution failed: '
        '$error\n$stackTrace',
      );
    } finally {
      stopwatch.stop();
    }

    final evidence = TugboatPreTapEvidence(
      route: tx.origin.route,
      routeEpoch: tx.origin.routeEpoch,
      routeInstanceId: tx.origin.routeInstanceId,
      pointerPosition: tx.origin.startPosition,
      targetAnchor: target,
      inventory: inventory,
      semanticMap: semanticSnapshot?.map,
      semanticResolution: semanticSnapshot?.resolution,
      visualObservationGeneration: _visualObservationGeneration,
      frameCompletionSequence: _frameCompletionSequence,
      buildMicros: stopwatch.elapsedMicroseconds,
      failureReason: failureReason,
    );
    tx.preTapEvidence = evidence;
    _recordExplorationPreTapDiagnostic(tx, evidence);
  }

  TugboatTargetAnchor? _selectExplorationTapTarget({
    required TugboatTargetAnchor? rawTarget,
    required TugboatSceneInventory inventory,
    required TugboatViewportSemanticResolution? semanticResolution,
    required bool allowDismissibleBarrierTarget,
  }) {
    if (_isOpaquePlatformTarget(rawTarget)) return null;
    final semanticFingerprint = semanticResolution?.linkedFingerprint;
    if (semanticResolution?.status == 'matched_inventory_fallback' &&
        semanticFingerprint?.isNotEmpty == true) {
      final entry = _inventoryEntryForFingerprint(
        inventory,
        semanticFingerprint!,
      );
      if (entry != null && _isTapInventoryEntry(entry)) {
        return _targetAnchorFromInventory(
          entry,
          base: rawTarget,
          confidence: 'low',
        );
      }
    }

    if (semanticResolution?.status == 'matched_actionable' &&
        semanticFingerprint?.isNotEmpty == true) {
      final entry = _inventoryEntryForFingerprint(
        inventory,
        semanticFingerprint!,
      );
      if (entry != null && _isTapInventoryEntry(entry)) {
        if (rawTarget?.fingerprint == entry.fingerprint) return rawTarget;
        return _targetAnchorFromInventory(entry, base: rawTarget);
      }
    }

    final rawFingerprint = rawTarget?.fingerprint;
    if (rawFingerprint == null || rawFingerprint.isEmpty) return null;
    final entry = _inventoryEntryForFingerprint(inventory, rawFingerprint);
    if (entry == null ||
        (!_isTapInventoryEntry(entry) && !allowDismissibleBarrierTarget)) {
      return null;
    }
    return rawTarget;
  }

  TugboatSceneInventoryEntry? _inventoryEntryForFingerprint(
    TugboatSceneInventory inventory,
    String fingerprint,
  ) {
    for (final entry in inventory.elements) {
      if (entry.fingerprint == fingerprint ||
          entry.aliases.contains(fingerprint)) {
        return entry;
      }
    }
    return null;
  }

  TugboatSceneInventory? _sanitizeExplorationInventory(
    TugboatSceneInventory? inventory, {
    required String? rawTargetFingerprint,
    required bool retainBlockingOverlayTarget,
  }) {
    if (inventory == null) return null;
    final elements = inventory.elements
        .where(
          (entry) =>
              entry.tier != 'interactive' ||
              entry.actions.isNotEmpty ||
              (retainBlockingOverlayTarget &&
                  rawTargetFingerprint != null &&
                  (entry.fingerprint == rawTargetFingerprint ||
                      entry.aliases.contains(rawTargetFingerprint))),
        )
        .toList(growable: false);
    if (elements.isEmpty) return null;
    if (elements.length == inventory.elements.length) return inventory;
    final fingerprints = elements.map((entry) => entry.fingerprint).toList()
      ..sort();
    return TugboatSceneInventory(
      inventoryHash: tugboatLabelHash(fingerprints.join('|')),
      routeKey: inventory.routeKey,
      elements: elements,
    );
  }

  bool _isTapInventoryEntry(TugboatSceneInventoryEntry entry) =>
      entry.tier == 'interactive' &&
      entry.enabled != false &&
      entry.actions.isNotEmpty &&
      !entry.actions.every((action) => action == 'scroll');

  TugboatTargetAnchor _targetAnchorFromInventory(
    TugboatSceneInventoryEntry entry, {
    TugboatTargetAnchor? base,
    String? confidence,
  }) {
    return TugboatTargetAnchor(
      schemaVersion: base?.schemaVersion ?? 1,
      widgetType: entry.widgetType ?? base?.widgetType,
      role: entry.role ?? base?.role,
      fingerprint: entry.fingerprint,
      fingerprintConfidence: confidence ?? base?.fingerprintConfidence,
      tagFingerprint: base?.tagFingerprint,
      fingerprintParts: base?.fingerprint == entry.fingerprint
          ? base?.fingerprintParts ?? const {}
          : const {},
      canonicalPath: entry.canonicalPath,
      relativePosition: base?.relativePosition,
      enabled: entry.enabled ?? base?.enabled,
      actions: entry.actions,
    );
  }

  TugboatTargetResolutionFailureReason _targetFailureReason({
    required TugboatTargetAnchor? rawTarget,
    required TugboatViewportSemanticResolution? semanticResolution,
  }) {
    if (_isOpaquePlatformTarget(rawTarget)) {
      return TugboatTargetResolutionFailureReason.opaquePlatformView;
    }
    if (semanticResolution?.status == 'matched_actionable') {
      return TugboatTargetResolutionFailureReason.noActionableCandidate;
    }
    return TugboatTargetResolutionFailureReason.noTargetAtPoint;
  }

  bool _isOpaquePlatformTarget(TugboatTargetAnchor? target) {
    final widgetType = target?.widgetType;
    if (widgetType == null) return false;
    return widgetType.contains('AndroidView') ||
        widgetType.contains('UiKitView') ||
        widgetType.contains('PlatformView') ||
        widgetType.contains('Texture');
  }

  void _recordExplorationPreTapDiagnostic(
    InteractionTransaction tx,
    TugboatPreTapEvidence evidence,
  ) {
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: tx.origin.atMs,
        type: 'exploration_pre_tap_diagnostic',
        stream: TugboatEventStream.diagnostic,
        relatedEventId: tx.id,
        data: <String, Object?>{
          'version': 1,
          'outcome': evidence.failureReason?.wireName ?? 'captured',
          'buildMicros': evidence.buildMicros,
          'routeEpoch': evidence.routeEpoch,
          if (evidence.route != null) 'route': evidence.route,
          if (evidence.routeInstanceId != null)
            'routeInstanceId': evidence.routeInstanceId,
          'visualObservationGeneration': evidence.visualObservationGeneration,
          'frameCompletionSequence': evidence.frameCompletionSequence,
          if (evidence.inventoryHash != null)
            'inventoryHash': evidence.inventoryHash,
          if (evidence.semanticResolution != null)
            'semanticStatus': evidence.semanticResolution!.status,
        },
      ),
    );
  }

  /// Resolve tap-only evidence when input capture observes pointer-up. This is
  /// the latest point that keeps the existing route-causing tap attribution
  /// contract while avoiding this work for gestures that become scrolls.
  /// [position] must be the pointer-down origin so a slop-bounded release that
  /// lands on a sibling still matches the recognizer's original target.
  void _resolveTapEvidence(InteractionTransaction tx, Offset position) {
    final resolver = _anchorResolver;
    if (config.profile == TugboatCaptureProfile.exploration) {
      final evidence = tx.preTapEvidence;
      if (evidence == null) {
        tx.targetResolutionFailureReason =
            TugboatTargetResolutionFailureReason.noTargetAtPoint;
        return;
      }
      if (evidence.routeEpoch != tx.origin.routeEpoch ||
          evidence.routeInstanceId != tx.origin.routeInstanceId ||
          evidence.route != tx.origin.route) {
        tx.targetResolutionFailureReason =
            TugboatTargetResolutionFailureReason.staleRouteGeneration;
        return;
      }
      tx.targetAnchor = evidence.targetAnchor;
      tx.targetResolutionFailureReason = evidence.failureReason;
      final inventory = evidence.inventory;
      if (inventory != null) {
        _emitSceneInventory(inventory, emitViewportSemanticMap: false);
      }
      final semanticMap = evidence.semanticMap;
      if (semanticMap != null) {
        _viewportSemantics.publishTapSnapshot(
          TugboatViewportTapSnapshot(
            map: semanticMap,
            encodedPayload: semanticMap.toJson(),
            resolution: evidence.semanticResolution,
            buildMicros: evidence.buildMicros,
          ),
        );
      }
      if (evidence.semanticResolution != null &&
          _viewportSemanticMapDebugLogsEnabled) {
        tugboatLogViewportSemanticTapResolution(
          position,
          evidence.semanticResolution!,
        );
      }
      return;
    }
    if (config.profile == TugboatCaptureProfile.dormant) return;
    TugboatSceneInventory? tapInventory;
    if (resolver != null) {
      final tapContext = resolver.buildTapContext(
        tapPosition: position,
        route: _currentRoute,
        keyboardOpen: _isKeyboardOpen(),
        modalOpen: _isModalOpen(),
      );
      tx.targetAnchor = tapContext.target;
      tapInventory = tapContext.inventory;
      if (tapInventory != null) {
        _emitSceneInventory(tapInventory, emitViewportSemanticMap: false);
      }
    }
    final viewportResolution = _viewportSemantics.resolveTap(
      position: position,
      resolver: resolver,
      boundaryKey: _boundaryKey,
      inventory: tapInventory,
    );
    if (viewportResolution != null && _viewportSemanticMapDebugLogsEnabled) {
      tugboatLogViewportSemanticTapResolution(position, viewportResolution);
    }
  }

  TugboatCaptureCoordinate _sampleCaptureCoordinate({
    required Offset position,
    required String? frameId,
    required _CaptureRequestContext context,
  }) {
    final boundaryRect = context.boundaryLogicalRect;
    if (boundaryRect == null) {
      return const TugboatCaptureCoordinate.unavailable(
        unavailableReason: 'boundary_unavailable',
      );
    }
    final frame = frameId == null ? null : _session?.frameById(frameId);
    final provenance = frameId == null ? null : _frameProvenance[frameId];
    if (frame != null &&
        provenance != null &&
        provenance.context.boundaryTransformGeneration !=
            context.boundaryTransformGeneration) {
      return TugboatCaptureCoordinate.unavailable(
        unavailableReason: 'generation_mismatch',
        boundaryOriginX: boundaryRect.left,
        boundaryOriginY: boundaryRect.top,
        boundaryWidth: boundaryRect.width,
        boundaryHeight: boundaryRect.height,
        framePixelWidth: frame.width,
        framePixelHeight: frame.height,
        frameId: frameId,
        boundaryTransformGeneration: context.boundaryTransformGeneration,
      );
    }
    final frameBoundaryRect =
        provenance?.context.boundaryLogicalRect ?? boundaryRect;
    return buildCaptureCoordinate(
      globalX: position.dx,
      globalY: position.dy,
      boundaryOriginX: frameBoundaryRect.left,
      boundaryOriginY: frameBoundaryRect.top,
      boundaryWidth: frameBoundaryRect.width,
      boundaryHeight: frameBoundaryRect.height,
      framePixelWidth: frame?.width ?? 0,
      framePixelHeight: frame?.height ?? 0,
      frameId: frameId,
      boundaryTransformGeneration: context.boundaryTransformGeneration,
    );
  }

  /// Retains route evidence until the claimed interaction reaches terminal
  /// gesture classification.
  void _attachCauseInteractionEvidence(
    String? causeEventId, {
    String? afterFrame,
  }) {
    if (causeEventId == null) return;
    final tx = _interactions.byId(causeEventId);
    if (tx == null) return;
    if (afterFrame != null) tx.afterFrame = afterFrame;
  }

  void _releaseInteractionClaim(InteractionTransaction tx) {
    final pointer = tx.pointerId;
    tx.sameTurnEligible = true;
    tx.releasedAtMs ??= atMs;
    _interactions.release(tx);
    final window = config.interactionClaimWindow;
    if (window <= Duration.zero) {
      // Microtask-only same-turn behaviour (characterization / rollback).
      scheduleMicrotask(() {
        if (!identical(_interactions.byPointer(pointer), tx)) return;
        tx.sameTurnEligible = false;
        _interactions.removeReleased(pointer);
        if (!tx.claimed && !tx.semanticPublished) {
          tx.rejectionReason ??= InteractionRejectionReason.expired;
        }
      });
      return;
    }
    tx.reconciliationDeadlineMs = atMs + window.inMilliseconds;
    _ensureReconciliationSweepScheduled();
  }

  void _ensureReconciliationSweepScheduled() {
    if (_reconciliationSweepScheduled) return;
    if (!_interactions.hasReleased) return;
    final earliest = _interactions.earliestReleasedDeadlineMs();
    if (earliest == null) return;
    final now = atMs;
    final delayMs = earliest - now;
    final delay = Duration(milliseconds: delayMs < 0 ? 0 : delayMs);
    _reconciliationSweepScheduled = true;
    final scheduled = _scheduleDelay(delay);
    _reconciliationSweepCancel = scheduled.cancel;
    unawaited(
      scheduled.done.then((_) {
        _reconciliationSweepScheduled = false;
        _reconciliationSweepCancel = null;
        if (_disposed) return;
        _sweepReleasedInteractions();
        if (_interactions.hasReleased) {
          _ensureReconciliationSweepScheduled();
        }
      }),
    );
  }

  void _sweepReleasedInteractions() {
    final now = atMs;
    final expired = <InteractionTransaction>[];
    for (final tx in _interactions.released) {
      final deadline = tx.reconciliationDeadlineMs;
      if (deadline == null) continue;
      if (now < deadline) continue;
      expired.add(tx);
    }
    for (final tx in expired) {
      _expireReleasedInteraction(tx);
    }
    // Enforce cap by flushing oldest safely.
    while (_interactions.releasedCount >
        tugboatMaxReleasedInteractionTransactions) {
      final oldest = _interactions.released.first;
      _expireReleasedInteraction(oldest);
    }
  }

  void _expireReleasedInteraction(InteractionTransaction tx) {
    tx.sameTurnEligible = false;
    if (!tx.claimed && !tx.cancelled) {
      tx.rejectionReason ??= InteractionRejectionReason.expired;
    }
    _interactions.removeReleased(tx.pointerId);
  }

  void _clearReleasedInteractions({
    InteractionRejectionReason reason = InteractionRejectionReason.sessionEnd,
  }) {
    _reconciliationSweepCancel?.call();
    _reconciliationSweepCancel = null;
    _reconciliationSweepScheduled = false;
    for (final tx in _interactions.takeAllReleased()) {
      _finalizeAbandonedTransaction(tx, reason: reason);
    }
  }

  /// Ensures every transaction reaches exactly one terminal canonical state.
  void _finalizeAbandonedTransaction(
    InteractionTransaction tx, {
    required InteractionRejectionReason reason,
  }) {
    if (tx.semanticPublished) return;
    _clearCausalRouteState(tx.id);
    _discardScrollCompletionFor(tx);
    tx.cancelled = true;
    tx.rejectionReason ??= reason;
    tx.attribution = InteractionAttribution.none;
    if (!tx.skipsTapSettlement) {
      tx.gesture = InteractionGesture.cancelled;
    }
    _publishCanonicalInteraction(tx);
  }

  void _abandonPendingPointer(int pointer, {required String gestureFinal}) {
    final pending = _interactions.removePending(pointer);
    if (pending == null) return;
    final reason = switch (gestureFinal) {
      'superseded' => InteractionRejectionReason.claimConsumed,
      'session_end' => InteractionRejectionReason.sessionEnd,
      _ => InteractionRejectionReason.lifecycle,
    };
    _finalizeAbandonedTransaction(pending, reason: reason);
  }

  void _abandonAllPendingPointers({String gestureFinal = 'session_end'}) {
    for (final pointer in _interactions.takePendingPointers()) {
      _abandonPendingPointer(pointer, gestureFinal: gestureFinal);
    }
  }

  void recordPointerCancel(Offset position, {int pointer = 0}) {
    if (!_acceptsPointerInput) return;
    final pending = _interactions.removePending(pointer);
    if (pending != null) {
      _discardScrollCompletionFor(pending);
      pending.gesture = InteractionGesture.cancelled;
      pending.rejectionReason ??= InteractionRejectionReason.lifecycle;
      _clearCausalRouteState(pending.id);
      _publishCanonicalInteraction(pending);
    }
    final released = _interactions.removeReleased(pointer);
    if (released != null) {
      _discardScrollCompletionFor(released);
      released.rejectionReason ??= InteractionRejectionReason.lifecycle;
      _finalizeAbandonedTransaction(
        released,
        reason: InteractionRejectionReason.lifecycle,
      );
    }
    if (!_disposed) notifyListeners();
  }

  void markPendingTapAsSwipe(int pointer) {
    final pending = _interactions.pendingAt(pointer);
    if (pending != null) {
      pending.markSwipe();
      pending.rejectionReason ??=
          InteractionRejectionReason.gestureReclassified;
    }
  }

  void markPendingClusterGesture({
    required int pointer,
    required InteractionGesture gesture,
    double scale = 1,
    int pointerCount = 2,
  }) {
    final pending = _interactions.pendingAt(pointer);
    if (pending == null) return;
    pending.markCluster(
      gesture: gesture,
      scale: scale,
      pointerCount: pointerCount,
    );
    pending.rejectionReason ??= InteractionRejectionReason.gestureReclassified;
  }

  void markPendingScaleGesture({
    required int pointer,
    required InteractionGesture gesture,
    double scale = 1,
    int pointerCount = 2,
  }) {
    markPendingClusterGesture(
      pointer: pointer,
      gesture: gesture,
      scale: scale,
      pointerCount: pointerCount,
    );
  }

  /// Drops a pending pointer without publishing an interaction.
  ///
  /// Used when a secondary pointer is absorbed into a pan/zoom gesture.
  void suppressPendingPointer(int pointer) {
    final pending = _interactions.removePending(pointer);
    if (pending == null || pending.semanticPublished) return;
    _discardScrollCompletionFor(pending);
    _clearCausalRouteState(pending.id);
    pending.semanticPublished = true;
    _interactions.forgetId(pending.id);
  }

  void recordPointerUp(Offset position, {int pointer = 0}) {
    if (!_acceptsPointerInput) return;
    final pending = _interactions.removePending(pointer);
    if (pending == null) return;
    pending.releasedAtMs = atMs;
    pending.releasedFrameSequence = _frameCompletionSequence;

    if (pending.isPanOrZoom) {
      final isZoom =
          pending.gesture == InteractionGesture.zoomIn ||
          pending.gesture == InteractionGesture.zoomOut;
      if (isZoom || pending.scrollStartEventIds.isEmpty) {
        pending.endPosition = position;
        _clearCausalRouteState(pending.id);
        _publishCompletedGestureAfterCapture(pending);
        if (!_disposed) notifyListeners();
        return;
      }
    }

    if (pending.skipsTapSettlement) {
      final scrollStartEventId = pending.scrollStartEventIds.isNotEmpty
          ? pending.scrollStartEventIds.first
          : null;
      final scrolled = scrollStartEventId != null;
      pending.gesture = scrolled
          ? InteractionGesture.scroll
          : InteractionGesture.swipe;
      pending.endPosition = position;
      _clearCausalRouteState(pending.id);
      if (scrollStartEventId == null) {
        _publishCompletedGestureAfterCapture(pending);
      } else {
        _scrollInteractions[scrollStartEventId] = pending;
        _publishResolvedScrollInteraction(scrollStartEventId);
      }
      if (!_disposed) notifyListeners();
      return;
    }

    _resolveTapEvidence(pending, pending.origin.startPosition);
    // Keep the single-use claim alive through the pointer-up turn so sync
    // onTap → Navigator can attribute without letting later redirects borrow.
    _releaseInteractionClaim(pending);

    final work = _TapSettleWork(session: _session);
    _activeTapSettles.add(work);
    unawaited(_resolveTapSettle(work, pending, position, _activeRouteCapture));
  }

  Future<void> _resolveTapSettle(
    _TapSettleWork work,
    InteractionTransaction pending,
    Offset position,
    _RouteCaptureWork? routeCaptureAtPointerUp,
  ) async {
    try {
      final initialRouteCapture =
          routeCaptureAtPointerUp?.change.causeEventId == pending.id
          ? routeCaptureAtPointerUp
          : null;
      // Give a callback immediately after pointer-up the same settle boundary.
      if (initialRouteCapture == null && config.settleDelay > Duration.zero) {
        final deadline = _scheduleDelay(config.settleDelay);
        work.attachDeadlineCancellation(deadline.cancel);
        await deadline.done;
      }
      if (!_isActiveTapSettle(work)) return;
      // Hold finalization open through the reconciliation window so a delayed
      // route/modal can claim before we publish unknown/unchanged.
      if (config.interactionClaimWindow > Duration.zero &&
          !pending.claimed &&
          pending.reconciliationDeadlineMs != null) {
        final remainingMs = pending.reconciliationDeadlineMs! - atMs;
        if (remainingMs > 0) {
          final deadline = _scheduleDelay(Duration(milliseconds: remainingMs));
          work.attachDeadlineCancellation(deadline.cancel);
          await pending.awaitSuccessorOrDeadline(deadline.done);
          deadline.cancel();
        }
      }
      if (!_isActiveTapSettle(work)) return;
      // A tap may only inherit a route barrier that was causally claimed by
      // that exact tap. In particular, an automatic navigation that starts
      // while this tap is waiting to settle is independent evidence: joining
      // it would incorrectly copy its destination frame and route event ID
      // onto the tap.
      final interactionRouteEpoch = pending.origin.routeEpoch;
      final interactionRoute = pending.origin.route;
      var currentRouteCapture = _activeRouteCapture;
      var routeCapture =
          initialRouteCapture ??
          (currentRouteCapture?.change.causeEventId == pending.id
              ? currentRouteCapture
              : _causalRouteCaptures[pending.id]);
      if (routeCapture == null && config.settleDelay <= Duration.zero) {
        // Flutter delivers some gesture callbacks, such as ModalBarrier
        // dismissal, after pointer-up. Yield one microtask before starting a
        // standalone screenshot so a synchronous route claim can own its
        // forced route frame without leaving a pending timer in widget tests.
        await Future<void>.microtask(() {});
        if (!_isActiveTapSettle(work)) return;
        currentRouteCapture = _activeRouteCapture;
        routeCapture = currentRouteCapture?.change.causeEventId == pending.id
            ? currentRouteCapture
            : _causalRouteCaptures[pending.id];
      }
      _TapSettleObservation observation;
      if (routeCapture != null) {
        _causalRouteCaptures.remove(pending.id);
        final routeBarrier = await _awaitRouteCaptureBarrier(
          routeCapture,
          expectedCauseEventId: pending.id,
        );
        if (!_isActiveTapSettle(work)) return;
        // The route capture is a forced fresh frame and belongs to this
        // claimed interaction. Reuse it here instead of scheduling a second
        // interaction capture that can delay later route ownership.
        final barrierWasSupersededByAutomatic =
            routeBarrier.result.outcome == _RouteCaptureOutcome.cancelled &&
            routeBarrier.work.change.causeEventId == pending.id &&
            routeBarrier.work.supersededBy?.change.causeEventId != pending.id;
        if (barrierWasSupersededByAutomatic) {
          // The claimed route did not settle, but a later route frame remains
          // a truthful temporal observation after this interaction. Follow the
          // visual successor without assigning its route event as causal.
          final successor = routeBarrier.work.supersededBy;
          String? temporalAfterFrame;
          String? temporalCaptureRequestId;
          if (successor != null) {
            final temporalBarrier = await _awaitRouteCaptureBarrier(successor);
            temporalAfterFrame = _temporalAfterFrame(
              pending,
              temporalBarrier.result.frameId,
            );
            if (temporalAfterFrame != null) {
              temporalCaptureRequestId =
                  temporalBarrier.result.captureRequestId;
            }
          }
          if (!_isActiveTapSettle(work)) return;
          observation = _TapSettleObservation(
            routeEpoch: _routeEpoch,
            route: _currentRoute,
            afterFrame: temporalAfterFrame,
            navigationOutcome: 'navigation_unavailable',
            captureOutcome: 'superseded_route_epoch',
            captureFailure: 'superseded_route_epoch',
            captureRequestId: temporalCaptureRequestId,
          );
        } else {
          observation = _tapObservationFromRouteBarrier(pending, routeBarrier);
        }
      } else {
        final requestedRouteEpoch = _routeEpoch;
        final requestedRoute = _currentRoute;
        final routeChangedFromOrigin =
            requestedRouteEpoch != interactionRouteEpoch ||
            requestedRoute != interactionRoute ||
            _causalRouteSupersededInteractions.contains(pending.id);
        final capture = _requestCaptureCancellable(
          trigger: TugboatFrameTrigger.interaction,
          force: true,
          settleDelay: Duration.zero,
          relatedEventId: pending.id,
        );
        work.attachCaptureCancellation((reason) => capture.cancel(reason));
        final captureResolution = await capture.resolution;
        final afterFrame = captureResolution.frameId;
        if (!_isActiveTapSettle(work)) return;
        final provenance = afterFrame == null
            ? null
            : _frameProvenance[afterFrame];
        // A standalone interaction capture belongs to the immutable
        // pointer-down route epoch. A later automatic route can be a useful
        // visual successor, but it cannot supply this interaction's evidence.
        final frameMatchesOrigin =
            afterFrame != null &&
            provenance != null &&
            provenance.context.routeEpoch == interactionRouteEpoch &&
            provenance.context.route == interactionRoute;
        final replacementRoute = _activeRouteCapture;
        final replacementIsCausal =
            replacementRoute?.change.causeEventId == pending.id;
        final captureWasSuperseded =
            routeChangedFromOrigin ||
            (!frameMatchesOrigin &&
                captureResolution.outcome == _CaptureOutcome.supersededRoute);
        if (!frameMatchesOrigin &&
            replacementRoute != null &&
            replacementRoute.epoch != requestedRouteEpoch) {
          final routeBarrier = await _awaitRouteCaptureBarrier(
            replacementRoute,
            expectedCauseEventId: replacementIsCausal ? pending.id : null,
          );
          if (!_isActiveTapSettle(work)) return;
          final successor = _tapObservationFromRouteBarrier(
            pending,
            routeBarrier,
            navigationOutcome: replacementIsCausal
                ? 'navigated'
                : 'visual_successor',
          );
          // The successor frame is a temporal post-interaction observation.
          // Only routeEventId remains gated by causal ownership.
          observation = _TapSettleObservation(
            routeEpoch: successor.routeEpoch,
            route: successor.route,
            afterFrame: _temporalAfterFrame(pending, successor.afterFrame),
            navigationOutcome: successor.navigationOutcome,
            captureOutcome: replacementIsCausal
                ? captureResolution.outcome.wireName
                : 'superseded_route_epoch',
            captureFailure: replacementIsCausal
                ? captureResolution.outcome.wireName
                : 'superseded_route_epoch',
            routeEventId: replacementIsCausal ? successor.routeEventId : null,
            captureRequestId: captureResolution.requestId,
          );
        } else {
          final temporalAfterFrame =
              frameMatchesOrigin && !routeChangedFromOrigin
              ? afterFrame
              : _temporalAfterFrame(pending, _latestFrameId);
          observation = _TapSettleObservation(
            routeEpoch: requestedRouteEpoch,
            route: requestedRoute,
            afterFrame: temporalAfterFrame,
            navigationOutcome: 'same_route',
            captureOutcome: frameMatchesOrigin && !routeChangedFromOrigin
                ? 'captured'
                : captureWasSuperseded
                ? 'superseded_route_epoch'
                : 'failed',
            captureFailure: frameMatchesOrigin && !routeChangedFromOrigin
                ? null
                : captureWasSuperseded
                ? 'superseded_route_epoch'
                : captureResolution.outcome.wireName,
            captureRequestId: captureResolution.requestId,
          );
        }
      }
      Future<void> writeSettle() async {
        if (!_isActiveTapSettle(work)) return;
        final afterFrame = observation.afterFrame;
        pending.gesture = InteractionGesture.tap;
        pending.afterFrame = afterFrame;
        _publishCanonicalInteraction(pending);

        if (!_disposed) notifyListeners();
      }

      // Route barriers may time out while the ordinary event queue is blocked.
      // Publish that one degraded, frame-less observation immediately rather
      // than letting it be replaced by unrelated later route state.
      if (observation.isDegraded) {
        try {
          await writeSettle();
        } catch (error, stackTrace) {
          debugPrint(
            '[tugboat] interaction settle failed: $error\n$stackTrace',
          );
        }
      } else {
        await _enqueue('interaction_settle', writeSettle);
      }
    } finally {
      _activeTapSettles.remove(work);
      _clearCausalRouteState(pending.id);
      work.complete();
    }
  }

  /// Returns a frame only as a temporal observation made after [interaction].
  /// This does not claim that the interaction caused the frame's route or UI.
  String? _temporalAfterFrame(
    InteractionTransaction interaction,
    String? frameId,
  ) {
    if (frameId == null) return null;
    final provenance = _frameProvenance[frameId];
    if (provenance == null || !provenance.available) return null;
    if (provenance.context.captureSessionId != _session?.id) return null;
    final observationBoundary =
        interaction.releasedAtMs ?? interaction.origin.atMs;
    if (provenance.completedAtMs < observationBoundary) return null;
    final releasedFrameSequence = interaction.releasedFrameSequence;
    if (releasedFrameSequence != null &&
        provenance.sequence <= releasedFrameSequence) {
      return null;
    }
    return frameId;
  }

  Future<String?> _temporalAfterFrameAfterCapture(
    InteractionTransaction interaction,
    _CaptureResolution resolution,
  ) async {
    final capturedFrame = _temporalAfterFrame(interaction, resolution.frameId);
    if (resolution.outcome == _CaptureOutcome.freshAccepted &&
        capturedFrame != null) {
      return capturedFrame;
    }

    var routeCapture = _activeRouteCapture;
    if (routeCapture == null) {
      // A route callback can start later in the same pointer-up event turn.
      // Give it one microtask to register before the fallback frame lookup.
      await Future<void>.microtask(() {});
      routeCapture = _activeRouteCapture;
    }
    final visited = <_RouteCaptureWork>{};
    while (routeCapture != null && visited.add(routeCapture)) {
      final barrier = await _awaitRouteCaptureBarrier(routeCapture);
      final routeFrame = _temporalAfterFrame(
        interaction,
        barrier.result.frameId,
      );
      if (routeFrame != null) return routeFrame;
      routeCapture = barrier.work.supersededBy;
    }
    return _temporalAfterFrame(interaction, _latestFrameId);
  }

  bool _isActiveTapSettle(_TapSettleWork work) =>
      !work.cancelled &&
      !_disposed &&
      _captureLifecycleActive &&
      _endSessionFuture == null &&
      identical(_session, work.session);

  _TapSettleObservation _tapObservationFromRouteBarrier(
    InteractionTransaction interaction,
    ({_RouteCaptureWork work, _RouteCaptureResult result}) routeBarrier, {
    String navigationOutcome = 'navigated',
  }) {
    final settledRoute = routeBarrier.work;
    final routeResult = routeBarrier.result;
    final frameId = routeResult.frameId;
    final provenance = frameId == null ? null : _frameProvenance[frameId];
    final validFrame =
        frameId != null &&
        provenance != null &&
        provenance.context.captureSessionId == _session?.id &&
        provenance.context.routeEpoch == settledRoute.epoch &&
        provenance.context.route == settledRoute.change.destinationRoute;
    return _TapSettleObservation(
      routeEpoch: settledRoute.epoch,
      route: settledRoute.change.destinationRoute,
      afterFrame: _temporalAfterFrame(interaction, validFrame ? frameId : null),
      navigationOutcome: validFrame
          ? navigationOutcome
          : 'navigation_unavailable',
      captureOutcome: validFrame
          ? 'captured'
          : routeResult.outcome == _RouteCaptureOutcome.timedOut
          ? 'timed_out'
          : 'failed',
      captureFailure: validFrame ? null : routeResult.captureFailure,
      routeEventId: routeResult.routeEventId,
      captureRequestId: routeResult.captureRequestId,
    );
  }

  void _cancelActiveTapSettles([String reason = 'manual']) {
    for (final work in List<_TapSettleWork>.from(_activeTapSettles)) {
      work.cancel(reason);
    }
    _activeTapSettles.clear();
  }

  bool _linkScrollStartToActiveGestures(String scrollStartEventId) {
    // A ScrollNotification does not identify a pointer. Give it one stable
    // owner so a shared start ID cannot make pointer-up transactions replace
    // each other in _scrollInteractions. Other active pointers remain swipes
    // and receive their own interaction captures.
    for (final tx in _interactions.pending) {
      if (!tx.scrollStartEventIds.contains(scrollStartEventId)) {
        tx.scrollStartEventIds.add(scrollStartEventId);
      }
      return true;
    }
    return false;
  }

  void _publishCanonicalInteraction(InteractionTransaction tx) {
    if (tx.semanticPublished) return;
    tx.semanticPublished = true;
    final payload = buildInteractionV2Payload(tx);
    tx.discardPreTapEvidence();
    _addEvent(
      TugboatEvent(
        id: tx.id,
        atMs: tx.origin.atMs,
        type: 'interaction',
        stream: TugboatEventStream.semantic,
        beforeFrame: tx.origin.beforeFrame,
        afterFrame: tx.afterFrame,
        data: payload,
        explorationRunId: tx.origin.explorationRunId,
        actionId: tx.origin.actionId,
      ),
    );
    _interactions.forgetId(tx.id);
  }

  void _clearCausalRouteState(String interactionId) {
    _causalRouteCaptures.remove(interactionId);
    _causalRouteSupersededInteractions.remove(interactionId);
  }

  void _cancelDeferredScrollEndCaptures(String outcome) {
    final pendingIds = _pendingScrollEndDelayCancellations.keys.toList(
      growable: false,
    );
    for (final id in pendingIds) {
      _pendingScrollEndDelayCancellations.remove(id)?.call();
      final completion = _pendingScrollCompletions[id];
      if (completion != null && !completion.resolved) {
        completion
          ..captureOutcome = outcome
          ..resolved = true;
        scheduleMicrotask(() => _publishResolvedScrollInteraction(id));
      }
    }
  }

  void _clearScrollCompletionState() {
    _cancelDeferredScrollEndCaptures('capture_cancelled');
    _pendingScrollEndDelayCancellations.clear();
    _scrollTrackers.clear();
    _scrollInteractions.clear();
    _pendingScrollCompletions.clear();
  }

  void _finalizeScrollCompletionInteractions(
    InteractionRejectionReason reason,
  ) {
    final transactions = _scrollInteractions.values.toSet();
    for (final tx in transactions) {
      _finalizeAbandonedTransaction(tx, reason: reason);
    }
  }

  void _finalizeActiveCompletedGestureCaptures(
    InteractionRejectionReason reason,
  ) {
    for (final tx in List<InteractionTransaction>.from(
      _activeCompletedGestureCaptures,
    )) {
      tx.afterFrame = null;
      tx.rejectionReason = reason;
      _finalizeAbandonedTransaction(tx, reason: reason);
    }
    _activeCompletedGestureCaptures.clear();
  }

  void _discardScrollCompletionFor(InteractionTransaction tx) {
    for (final scrollStartEventId in tx.scrollStartEventIds) {
      _pendingScrollEndDelayCancellations.remove(scrollStartEventId)?.call();
      _scrollInteractions.remove(scrollStartEventId);
      _pendingScrollCompletions.remove(scrollStartEventId);
      for (final tracker in _scrollTrackers.values) {
        if (tracker.startEventId == scrollStartEventId) {
          tracker.pointerLinked = false;
        }
      }
    }
  }

  void _publishResolvedScrollInteraction(String scrollStartEventId) {
    final completion = _pendingScrollCompletions[scrollStartEventId];
    final interaction = _scrollInteractions[scrollStartEventId];
    if (completion == null ||
        interaction == null ||
        !completion.resolved ||
        completion.publishing) {
      return;
    }
    completion.publishing = true;
    // Final scroll facts are independent from the delayed screenshot. Apply
    // them before any cancellation or replacement path can publish the event.
    completion.applyTo(interaction);
    _activeCompletedGestureCaptures.add(interaction);
    final task = () async {
      final resolution = completion.captureResolution;
      final afterFrame = resolution == null
          ? completion.afterFrame
          : await _temporalAfterFrameAfterCapture(interaction, resolution);
      if (!identical(
            _pendingScrollCompletions[scrollStartEventId],
            completion,
          ) ||
          !identical(_scrollInteractions[scrollStartEventId], interaction) ||
          interaction.semanticPublished) {
        return;
      }
      interaction.afterFrame = afterFrame;
      _publishCanonicalInteraction(interaction);
      _scrollInteractions.remove(scrollStartEventId);
      _pendingScrollCompletions.remove(scrollStartEventId);
    }();
    _activeCompletedGestureTasks.add(task);
    unawaited(
      task.whenComplete(() {
        completion.publishing = false;
        _activeCompletedGestureCaptures.remove(interaction);
        _activeCompletedGestureTasks.remove(task);
      }),
    );
  }

  /// A completed swipe, scroll, pan, or zoom gets its own fresh after-frame. Interaction
  /// requests never coalesce, and fresh-paint capture cannot reuse a content
  /// hash or perceptual hash frame.
  void _publishCompletedGestureAfterCapture(InteractionTransaction tx) {
    final session = _session;
    final lifecycleEpoch = _captureLifecycleEpoch;
    _activeCompletedGestureCaptures.add(tx);
    late final Future<void> task;
    task = () async {
      try {
        final capture = _requestCaptureCancellable(
          trigger: TugboatFrameTrigger.interaction,
          force: true,
          settleDelay: Duration.zero,
          relatedEventId: tx.id,
        );
        final resolution = await capture.resolution;
        if (!_isCaptureLifecycleCurrent(session, lifecycleEpoch)) return;
        tx.afterFrame = await _temporalAfterFrameAfterCapture(tx, resolution);
        if (!_isCaptureLifecycleCurrent(session, lifecycleEpoch)) return;
        await _enqueue('interaction_after_capture', () async {
          if (!_isCaptureLifecycleCurrent(session, lifecycleEpoch)) return;
          _publishCanonicalInteraction(tx);
          if (!_disposed) notifyListeners();
        });
      } finally {
        _activeCompletedGestureCaptures.remove(tx);
        _activeCompletedGestureTasks.remove(task);
      }
    }();
    _activeCompletedGestureTasks.add(task);
    unawaited(task);
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
    // A new scroll means the viewport is no longer idle. Cancel any deferred
    // scroll-end capture; its interaction completes without visual evidence.
    _cancelDeferredScrollEndCaptures('superseded_by_scroll');
    final scrollableElement = _scrollableElementFor(scrollContext);
    if (scrollableElement == null) return;
    if (_scrollTrackers.containsKey(scrollableElement)) return;

    final targetAnchor = _resolveScrollableAnchor(scrollableElement);
    final sectionLabel = _sectionLabelFor(scrollableElement);
    final attachmentContext = _captureContext(TugboatFrameTrigger.scroll);
    final beforeFrame = _compatibleFrameFor(attachmentContext);
    final startEventId = _nextId('event');
    final pageStart = metrics is PageMetrics ? metrics.page : null;

    final tracker = _ScrollTracker(
      scrollableElement: scrollableElement,
      startEventId: startEventId,
      startedAtMs: atMs,
      startOffset: metrics.pixels,
      routeEpoch: _routeEpoch,
      beforeFrame: beforeFrame,
      targetAnchor: targetAnchor,
      sectionLabel: sectionLabel,
      axis: metrics.axis.name,
      depth: depth,
      maxScrollExtent: metrics.maxScrollExtent,
      pointerLinked: false,
      pageStart: pageStart,
    );
    _scrollTrackers[scrollableElement] = tracker;

    final session = _session;
    if (session != null && config.captureScrollSamples) {
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

    _maybeEmitSceneInventory(
      scrollContext: _scrollSemanticContext(
        trigger: 'scroll_start',
        metrics: metrics,
        tracker: tracker,
      ),
    );
    tracker.pointerLinked = _linkScrollStartToActiveGestures(startEventId);
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

    final now = DateTime.now();
    final sampleDue =
        config.captureScrollSamples &&
        (tracker.lastSampleAt == null ||
            now.difference(tracker.lastSampleAt!) >=
                config.scrollCaptureInterval);
    if (sampleDue) {
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
    }

    final screenshotDue =
        config.captureScrollScreenshots &&
        (tracker.lastScreenshotAt == null ||
            now.difference(tracker.lastScreenshotAt!) >=
                config.scrollCaptureInterval);
    if (screenshotDue) {
      tracker.lastScreenshotAt = now;
      unawaited(
        _requestCaptureCancellable(
          trigger: TugboatFrameTrigger.scroll,
          dropWhenBusy: true,
        ).done,
      );
    }
    if (!sampleDue && !screenshotDue) return;
    // Debounce semantic/inventory rebuilds during continuous scroll. Scroll
    // metrics are independent from visual capture; scroll_end forces the final
    // semantic update.
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

    if (!tracker.pointerLinked) {
      // Programmatic scrolls retain evidence, but do not manufacture an
      // interaction capture or bypass local-WebSocket suppression.
      _enqueue('scroll_end', () async {
        if (!_isCaptureLifecycleCurrent(
          captureSession,
          captureLifecycleEpoch,
        )) {
          return;
        }
        _maybeEmitSceneInventory(
          scrollContext: _scrollSemanticContext(
            trigger: 'scroll_end',
            metrics: metrics,
            tracker: tracker,
            endOffset: metrics.pixels,
          ),
        );
        if (!_disposed) notifyListeners();
      });
      return;
    }

    final completion = _PendingScrollCompletion(
      startOffset: tracker.startOffset,
      endOffset: metrics.pixels,
      overscrollCount: tracker.overscrollCount,
      targetAnchor: tracker.targetAnchor,
    );
    _pendingScrollCompletions[tracker.startEventId] = completion;
    final idleDeadline = config.scrollEndCaptureDelay > Duration.zero
        ? _scheduleDelay(config.scrollEndCaptureDelay)
        : (done: Future<void>.value(), cancel: () {});
    _pendingScrollEndDelayCancellations[tracker.startEventId] =
        idleDeadline.cancel;

    // Scroll-end capture is deliberately outside the controller task queue.
    // It may wait for the viewport to settle, but must not delay pointer, route,
    // or interaction work that arrives meanwhile.
    unawaited(() async {
      await idleDeadline.done;
      final wasPending =
          _pendingScrollEndDelayCancellations.remove(tracker.startEventId) !=
          null;
      if (!wasPending || completion.resolved) return;
      if (!_isCaptureLifecycleCurrent(captureSession, captureLifecycleEpoch)) {
        return;
      }
      if (tracker.routeEpoch != _routeEpoch) {
        // Make the interaction capture attempt. A later route frame can be a
        // temporal observation, but it does not make the route scroll-caused.
        final afterCapture = _requestCaptureCancellable(
          trigger: TugboatFrameTrigger.interaction,
          force: true,
          settleDelay: Duration.zero,
          relatedEventId: tracker.startEventId,
        );
        final afterResolution = await afterCapture.resolution;
        if (!_isCaptureLifecycleCurrent(
          captureSession,
          captureLifecycleEpoch,
        )) {
          return;
        }
        completion
          ..captureResolution = afterResolution
          ..captureOutcome = 'superseded_route_epoch'
          ..resolved = true;
        _publishResolvedScrollInteraction(tracker.startEventId);
        if (!_disposed) notifyListeners();
        return;
      }
      final afterCapture = _requestCaptureCancellable(
        trigger: TugboatFrameTrigger.interaction,
        force: true,
        settleDelay: Duration.zero,
        relatedEventId: tracker.startEventId,
      );
      final afterResolution = await afterCapture.resolution;
      if (!_isCaptureLifecycleCurrent(captureSession, captureLifecycleEpoch)) {
        return;
      }
      final afterFrame =
          afterResolution.outcome == _CaptureOutcome.freshAccepted
          ? afterResolution.frameId
          : null;
      if (config.captureScrollSamples &&
          _session != null &&
          _session!.scrollSamples.isNotEmpty) {
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
      completion
        ..afterFrame = afterFrame
        ..captureResolution = afterResolution
        ..captureOutcome = afterResolution.outcome.wireName
        ..resolved = true;
      _publishResolvedScrollInteraction(tracker.startEventId);
      if (!_disposed) notifyListeners();
    }());
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

  Future<void> route(
    String type,
    Route<dynamic>? route, {
    NavigatorState? navigatorState,
    Route<dynamic>? departingRoute,
  }) {
    if (_disposed || _session == null || _endSessionFuture != null) {
      return Future<void>.value();
    }
    final transition = _parseRouteTransition(type, route);
    final change = _resolveVisibleRouteChange(
      transition,
      destinationRoute: route,
      departingRoute: departingRoute,
      navigatorState: navigatorState,
    );
    if (change == null) return Future<void>.value();

    if (change.updatesRoute) {
      _currentRoute = change.destinationRoute;
      _currentNavigatorId = change.navigatorId;
      _currentRouteInstanceId = change.routeInstanceId;
    }

    final captureKey = _routeCaptureKey(change.navigatorId);
    final prior = _activeRouteCaptures[captureKey];
    if (prior != null) {
      _activeRouteCaptures.remove(captureKey);
      if (_latestRouteCaptureKey == captureKey) {
        _latestRouteCaptureKey = _activeRouteCaptures.keys.isEmpty
            ? null
            : _activeRouteCaptures.keys.last;
      }
      prior.cancel('superseded_route');
      _cancelScheduledCaptureWaiters('superseded_route');
      _advanceCaptureGeneration();
    } else if (_activeRouteCaptures.isEmpty) {
      // A new visible route must also wake any unrelated in-flight frame wait.
      _advanceCaptureGeneration();
    }
    final work = _RouteCaptureWork(
      epoch: ++_routeEpoch,
      change: change,
      deadline:
          transition.transitionDuration +
          (_shouldSuppressFrameCapture && change.causeEventId == null
              ? Duration.zero
              : config.settleDelay),
    );
    _activeRouteCaptures[captureKey] = work;
    _latestRouteCaptureKey = captureKey;
    prior?.supersededBy = work;
    final priorCauseEventId = prior?.change.causeEventId;
    if (priorCauseEventId != null && priorCauseEventId != change.causeEventId) {
      // A later, unclaimed route superseded this interaction's route. It is
      // independent evidence and cannot supply the interaction's after-frame.
      _causalRouteCaptures.remove(priorCauseEventId);
      _causalRouteSupersededInteractions.add(priorCauseEventId);
    }
    if (change.causeEventId != null) {
      _causalRouteCaptures[change.causeEventId!] = work;
    }
    _skipCapture = transition.transitionDuration > Duration.zero;
    _startRouteBarrierTimeout(work);
    // Wake a reconciliation-pending settle only after this capture is visible
    // in `_activeRouteCaptures`, otherwise settle can miss the causal barrier.
    if (change.causeEventId != null) {
      _interactions.byId(change.causeEventId!)?.signalSuccessorClaimed();
    }
    if (work.deadline <= Duration.zero) {
      unawaited(_enqueue('route_change', () => _finalizeRouteCapture(work)));
    } else {
      _startRouteDeadline(work);
    }
    return work.done.then<void>((_) {});
  }

  bool _isActiveRouteCapture(_RouteCaptureWork work) {
    final key = _routeCaptureKey(work.change.navigatorId);
    return !_disposed &&
        !work.cancelled &&
        identical(_activeRouteCaptures[key], work);
  }

  /// Waits for a route epoch's single capture outcome. A causally attributed
  /// tap may follow only successors carrying the same claimed event ID.
  Future<({_RouteCaptureWork work, _RouteCaptureResult result})>
  _awaitRouteCaptureBarrier(
    _RouteCaptureWork work, {
    String? expectedCauseEventId,
  }) async {
    var candidate = work;
    while (true) {
      final result = await candidate.done;
      if (result.outcome == _RouteCaptureOutcome.captured) {
        return (work: candidate, result: result);
      }
      // Only explicit cancellation from a successor can transfer a waiter.
      // In particular, a timed-out route must not attach a tap to a later,
      // unrelated navigation.
      if (result.outcome != _RouteCaptureOutcome.cancelled) {
        return (work: candidate, result: result);
      }
      final replacement = candidate.supersededBy;
      if (replacement == null || identical(replacement, candidate)) {
        return (work: candidate, result: result);
      }
      if (expectedCauseEventId != null &&
          replacement.change.causeEventId != expectedCauseEventId) {
        return (work: candidate, result: result);
      }
      candidate = replacement;
    }
  }

  void _cancelActiveRouteCapture([String reason = 'manual']) {
    if (_activeRouteCaptures.isEmpty) {
      _causalRouteCaptures.clear();
      _causalRouteSupersededInteractions.clear();
      _skipCapture = false;
      return;
    }
    final active = List<_RouteCaptureWork>.from(_activeRouteCaptures.values);
    _activeRouteCaptures.clear();
    _causalRouteCaptures.clear();
    _causalRouteSupersededInteractions.clear();
    _latestRouteCaptureKey = null;
    _advanceCaptureGeneration();
    for (final work in active) {
      work.cancel(reason);
    }
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
    work.cancelPendingWork('route_timeout');
    _advanceCaptureGeneration();
    final key = _routeCaptureKey(work.change.navigatorId);
    if (identical(_activeRouteCaptures[key], work)) {
      _activeRouteCaptures.remove(key);
      if (_latestRouteCaptureKey == key) {
        _latestRouteCaptureKey = _activeRouteCaptures.keys.isEmpty
            ? null
            : _activeRouteCaptures.keys.last;
      }
    }
    _skipCapture = false;
    final routeEventId = _nextId('event');
    // This must not enqueue behind the blocked task that caused the timeout.
    // Dart's single isolate means the session mutation is still atomic with
    // respect to the next event-loop turn.
    _attachCauseInteractionEvidence(change.causeEventId);
    _emitRouteChange(
      routeEventId: routeEventId,
      change: change,
      result: TugboatInteractionResult.unknown,
      extraData: const {'captureOutcome': 'timed_out'},
    );
    work.complete(
      _RouteCaptureResult(
        _RouteCaptureOutcome.timedOut,
        routeEventId: routeEventId,
      ),
    );
    if (!_disposed) notifyListeners();
  }

  /// Emits one canonical `route_change` on the evidence stream.
  void _emitRouteChange({
    required String routeEventId,
    required _VisibleRouteChange change,
    required TugboatInteractionResult result,
    String? afterFrame,
    Map<String, Object?> extraData = const <String, Object?>{},
  }) {
    _addEvent(
      TugboatEvent(
        id: routeEventId,
        atMs: atMs,
        type: 'route_change',
        stream: TugboatEventStream.evidence,
        afterFrame: afterFrame,
        result: result,
        data: {
          if (change.previousRoute != null) 'fromRoute': change.previousRoute,
          if (change.destinationRoute != null) 'route': change.destinationRoute,
          'navigation': change.navigation,
          ...extraData,
          ...change.ownershipData(),
        },
      ),
    );
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
    String? routeEventId;
    String? captureFailure;
    String? captureRequestId;
    var outcome = _RouteCaptureOutcome.failed;
    try {
      if (!_isActiveRouteCapture(work)) return;
      final change = work.change;
      if (change.updatesRoute) {
        _currentRoute = change.destinationRoute;
        _currentNavigatorId = change.navigatorId;
        _currentRouteInstanceId = change.routeInstanceId;
      }
      final capture = _requestCaptureCancellable(
        trigger: TugboatFrameTrigger.route,
        force: true,
        bypassExplorationSuppression: change.causeEventId != null,
        // The route deadline already includes the configured post-route
        // settle. Scheduling it again here would delay capture twice and can
        // strand widget-backed callers waiting for route completion.
        settleDelay: Duration.zero,
      );
      work.attachCaptureCancellation((reason) => capture.cancel(reason));
      final captureResult = await _awaitRouteReadback(work, capture.resolution);
      captureRequestId = captureResult.captureRequestId;
      if (captureResult.outcome == _RouteCaptureOutcome.failed) {
        if (!_isActiveRouteCapture(work)) return;
        outcome = _RouteCaptureOutcome.failed;
        captureFailure = _lastCaptureFailure?.name;
        routeEventId = _nextId('event');
        _attachCauseInteractionEvidence(change.causeEventId);
        _emitRouteChange(
          routeEventId: routeEventId,
          change: change,
          result: TugboatInteractionResult.navigated,
          extraData: {
            'captureOutcome': 'failed',
            if (captureResult.captureFailure != null)
              'captureFailure': captureResult.captureFailure,
            if (captureRequestId != null) 'captureRequestId': captureRequestId,
          },
        );
        if (!_disposed) notifyListeners();
        return;
      }
      if (captureResult.outcome != _RouteCaptureOutcome.captured) return;
      afterFrame = captureResult.frameId;
      outcome = afterFrame == null
          ? _RouteCaptureOutcome.failed
          : _RouteCaptureOutcome.captured;
      if (outcome == _RouteCaptureOutcome.failed) {
        captureFailure = _lastCaptureFailure?.name;
      }
      if (!_isActiveRouteCapture(work)) return;
      routeEventId = _nextId('event');
      _attachCauseInteractionEvidence(
        change.causeEventId,
        afterFrame: afterFrame,
      );
      _emitRouteChange(
        routeEventId: routeEventId,
        change: change,
        afterFrame: afterFrame,
        result: TugboatInteractionResult.navigated,
        extraData: {
          if (captureRequestId != null) 'captureRequestId': captureRequestId,
          if (outcome == _RouteCaptureOutcome.failed)
            'captureOutcome': 'failed',
          if (outcome == _RouteCaptureOutcome.failed &&
              captureResult.captureFailure != null)
            'captureFailure': captureResult.captureFailure,
        },
      );
      _maybeEmitSceneInventory();
      if (!_disposed) notifyListeners();
    } finally {
      final key = _routeCaptureKey(work.change.navigatorId);
      if (identical(_activeRouteCaptures[key], work)) {
        _activeRouteCaptures.remove(key);
        if (_latestRouteCaptureKey == key) {
          _latestRouteCaptureKey = _activeRouteCaptures.keys.isEmpty
              ? null
              : _activeRouteCaptures.keys.last;
        }
        _skipCapture = false;
      }
      work.complete(
        _RouteCaptureResult(
          outcome,
          frameId: afterFrame,
          routeEventId: routeEventId,
          captureFailure: captureFailure,
          captureRequestId: captureRequestId,
        ),
      );
    }
  }

  /// Joins readback to the route's absolute terminal barrier. A timeout or
  /// cancellation wakes an already-admitted finalizer immediately instead of
  /// leaving the serialized queue blocked on platform readback.
  Future<_RouteCaptureResult> _awaitRouteReadback(
    _RouteCaptureWork work,
    Future<_CaptureResolution> capture,
  ) async {
    return Future.any<_RouteCaptureResult>([
      capture.then(
        (resolution) => _RouteCaptureResult(
          resolution.frameId == null
              ? _RouteCaptureOutcome.failed
              : _RouteCaptureOutcome.captured,
          frameId: resolution.frameId,
          captureFailure: resolution.outcome.wireName,
          captureRequestId: resolution.requestId,
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
        _cancelActiveTapSettles('lifecycle_deactivate');
        _cancelActiveRouteCapture('lifecycle_deactivate');
        _invalidateCaptureWork('lifecycle_deactivate');
        // Drop in-flight pointer claims so a later resume/navigation cannot
        // attribute itself to a pre-background gesture.
        _abandonAllPendingPointers(gestureFinal: 'lifecycle');
        _clearReleasedInteractions(
          reason: InteractionRejectionReason.lifecycle,
        );
        _finalizeActiveCompletedGestureCaptures(
          InteractionRejectionReason.lifecycle,
        );
        _finalizeScrollCompletionInteractions(
          InteractionRejectionReason.lifecycle,
        );
        _clearScrollCompletionState();
        _captureLifecycleActive = false;
        break;
      case AppLifecycleState.resumed:
        _captureLifecycleActive = true;
        unawaited(
          _requestCapture(
            trigger: TugboatFrameTrigger.lifecycle,
            force: true,
            settleDelay: Duration.zero,
          ),
        );
        break;
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
      overlayKind: _overlayKindFor(route),
    );
  }

  static String _overlayKindFor(Route<dynamic>? route) {
    if (route == null) return 'page';
    final typeName = route.runtimeType.toString();
    if (route is PopupRoute) {
      if (typeName.contains('ModalBottomSheet')) return 'modal';
      if (typeName.contains('Dialog')) return 'dialog';
      return 'popup';
    }
    if (typeName.contains('ModalBottomSheet')) return 'modal';
    if (typeName.contains('Dialog')) return 'dialog';
    return 'page';
  }

  /// Resolves [transition] against [_currentRoute], or returns null when it
  /// is not visible navigation.
  ///
  /// Stack-cleanup removals (e.g. `pushNamedAndRemoveUntil` clearing routes
  /// below the new top) resolve to null and must not bump the route epoch:
  /// doing so cancels the pending capture scheduled by the preceding push,
  /// dropping both the route_change event and its screenshot for the
  /// destination route.
  _VisibleRouteChange? _resolveVisibleRouteChange(
    _RouteTransition transition, {
    Route<dynamic>? destinationRoute,
    Route<dynamic>? departingRoute,
    NavigatorState? navigatorState,
  }) {
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

    String? navigatorId;
    String? parentNavigatorId;
    String? routeInstanceId;
    String? fromRouteInstanceId;
    var stackRevision = 0;
    if (navigatorState != null) {
      navigatorId = _surfaces.idForNavigator(navigatorState);
      parentNavigatorId = _surfaces.parentOf(navigatorId);
      switch (transition.kind) {
        case _RouteNavigationKind.push:
          if (destinationRoute != null) {
            routeInstanceId = _surfaces.idForRoute(destinationRoute);
            stackRevision = _surfaces.push(navigatorId, routeInstanceId);
          }
          fromRouteInstanceId = _currentRouteInstanceId;
        case _RouteNavigationKind.replace:
          if (destinationRoute != null) {
            routeInstanceId = _surfaces.idForRoute(destinationRoute);
            stackRevision = _surfaces.replaceTop(navigatorId, routeInstanceId);
          }
          fromRouteInstanceId =
              _surfaces.peekRouteId(departingRoute) ?? _currentRouteInstanceId;
        case _RouteNavigationKind.pop:
        case _RouteNavigationKind.remove:
          fromRouteInstanceId =
              _surfaces.peekRouteId(departingRoute) ?? _currentRouteInstanceId;
          stackRevision = _surfaces.pop(
            navigatorId,
            departingInstanceId: fromRouteInstanceId,
          );
          if (destinationRoute != null) {
            routeInstanceId = _surfaces.idForRoute(destinationRoute);
          } else {
            routeInstanceId = _surfaces.top(navigatorId);
          }
      }
    } else if (destinationRoute != null) {
      // Test harness / direct controller.route calls without a NavigatorState.
      routeInstanceId = _surfaces.idForRoute(destinationRoute);
      fromRouteInstanceId = _currentRouteInstanceId;
      stackRevision = (_currentRouteInstanceId == null ? 1 : 2);
    }

    _visualObservationGeneration++;
    final claimed = _tryClaimInteractionCause(
      navigatorId: navigatorId ?? _currentNavigatorId,
    );
    return _VisibleRouteChange(
      previousRoute: _currentRoute,
      destinationRoute: updatesRoute ? routeName : _currentRoute,
      navigation: transition.kind.wireName,
      updatesRoute: updatesRoute,
      navigatorId: navigatorId ?? _currentNavigatorId,
      parentNavigatorId: parentNavigatorId,
      routeInstanceId: routeInstanceId ?? _currentRouteInstanceId,
      fromRouteInstanceId: fromRouteInstanceId,
      stackRevision: stackRevision,
      overlayKind: transition.overlayKind,
      visualObservationGeneration: _visualObservationGeneration,
      navigationOrigin: claimed == null
          ? 'automatic_or_unknown'
          : 'interaction',
      causeEventId: claimed?.id,
      interactionAttribution: claimed?.attribution,
    );
  }

  /// Observer-time single-use claim. Returns the transaction only when exactly
  /// one unambiguous active pointer is eligible for this navigator/session.
  ///
  /// The route writer retains the claim until terminal publication, so a
  /// causeEventId remains stable across route and gesture settlement.
  InteractionTransaction? _tryClaimInteractionCause({String? navigatorId}) {
    if (!_captureLifecycleActive || _endSessionFuture != null) return null;
    final eligible = _interactions.eligibleForClaim(
      nowMs: atMs,
      sessionId: _session?.id,
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
    final windowActive = config.interactionClaimWindow > Duration.zero;
    final isPending = _interactions.pendingAt(tx.pointerId) != null;
    tx.attribution = (isPending || !windowActive)
        ? InteractionAttribution.direct
        : InteractionAttribution.delayedLikely;
    return tx;
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

    _emitSceneInventory(inventory, scrollContext: scrollContext);
  }

  void _emitSceneInventory(
    TugboatSceneInventory inventory, {
    bool emitViewportSemanticMap = true,
    TugboatViewportSemanticScrollContext? scrollContext,
  }) {
    if (config.profile != TugboatCaptureProfile.exploration) return;
    // Always emit raw scene_inventory first (when new). Semantic-map emission
    // must not replace or suppress inventory; maps are an exploration companion.
    final dedupeKey = [
      inventory.routeKey,
      inventory.inventoryHash,
      scrollContext?.dedupeKey ?? '',
    ].join('|');
    if (_emittedInventories.add(dedupeKey)) {
      _addEvent(
        TugboatEvent(
          id: _nextId('event'),
          atMs: atMs,
          type: 'scene_inventory',
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

  /// Publishes one timeline event.
  ///
  /// When [attachActionContext] is true (default), stamps the active
  /// exploration action window. Host app/network evidence passes false so it
  /// never inherits [actionId] or interaction context.
  void _addEvent(TugboatEvent event, {bool attachActionContext = true}) {
    final session = _session;
    if (session == null) return;
    final enriched = attachActionContext
        ? event.withExplorationContext(
            captureSessionId: session.id,
            activationRequestId:
                session.activationRequestId ?? activationRequestId,
            explorationRunId:
                event.explorationRunId ??
                _activeExplorationRunId ??
                config.explorationRunId,
            actionId: event.actionId ?? _activeActionId,
          )
        : event.copyWith(
            captureSessionId: event.captureSessionId ?? session.id,
            activationRequestId:
                event.activationRequestId ??
                session.activationRequestId ??
                activationRequestId,
            explorationRunId:
                event.explorationRunId ?? session.explorationRunId,
          );
    session.events.add(enriched);
    _sinkHub?.recordEvent(enriched);
    _trim();
  }

  /// Same-turn fence for [TugboatReplay.deactivate] without full session end.
  ///
  /// The activation gate still owns `session_end` on teardown; this only stops
  /// evidence admission for in-flight host callbacks.
  @internal
  void fenceEvidence() => _evidence.close();

  /// Records one logical host app/analytics event onto the evidence stream.
  ///
  /// Prefer [TugboatReplay.eventHook] — it applies lifecycle admission.
  @internal
  void recordExternalEvent({
    required String name,
    String? source,
    Map<String, Object?>? parameters,
    TugboatParameterPolicy parameterPolicy =
        TugboatParameterPolicy.allowAllInProduction,
  }) {
    _evidence.recordExternalEvent(
      name: name,
      source: source,
      parameters: parameters,
      parameterPolicy: parameterPolicy,
    );
  }

  /// Begins observation of one logical network call.
  ///
  /// Prefer [TugboatReplay.beginNetworkCall] — it applies lifecycle admission.
  @internal
  TugboatNetworkCall beginNetworkCall({required String method, String? route}) {
    return _evidence.beginNetworkCall(method: method, route: route);
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
      final provenance = _frameProvenance[removed.id];
      if (provenance != null) {
        _frameProvenance[removed.id] = provenance.unavailable();
      }
      // An older duplicate must not erase the mapping for a newer retained
      // logical frame with the same pixels.
      if (_hashToFrameId[removed.contentHash] == removed.id) {
        final replacement = session.frames.lastWhere(
          (frame) => frame.contentHash == removed.contentHash,
          orElse: () => removed,
        );
        if (identical(replacement, removed)) {
          _hashToFrameId.remove(removed.contentHash);
        } else {
          _hashToFrameId[removed.contentHash] = replacement.id;
        }
      }
      if (_latestFrameId == removed.id) {
        _latestFrameId = session.frames.isEmpty ? null : session.frames.last.id;
      }
      session.truncated = true;
    }
    _trimFrameMetadata(session);
  }

  void _trimFrameMetadata(TugboatSession session) {
    final retainedFrameIds = session.frames.map((frame) => frame.id).toSet();
    final referencedFrameIds = <String>{...retainedFrameIds};
    for (final event in session.events) {
      final beforeFrame = event.beforeFrame;
      if (beforeFrame != null) referencedFrameIds.add(beforeFrame);
      final afterFrame = event.afterFrame;
      if (afterFrame != null) referencedFrameIds.add(afterFrame);
    }
    for (final sample in session.scrollSamples) {
      final beforeFrame = sample.beforeFrame;
      if (beforeFrame != null) referencedFrameIds.add(beforeFrame);
      final afterFrame = sample.afterFrame;
      if (afterFrame != null) referencedFrameIds.add(afterFrame);
    }

    _frameProvenance.removeWhere(
      (frameId, _) => !referencedFrameIds.contains(frameId),
    );
    _frameReuseObservations.removeWhere(
      (frameId, _) => !referencedFrameIds.contains(frameId),
    );
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
