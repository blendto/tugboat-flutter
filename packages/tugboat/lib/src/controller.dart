import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'capture_profile.dart';
import 'capture_sink.dart';
import 'collector_http_sink.dart';
import 'coordinate_space.dart';
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
    required this.claim,
  });

  final String eventId;
  final TugboatTargetAnchor? targetAnchor;
  final TugboatStateAnchor? beforeState;
  final String? beforeFrame;
  final Offset startPosition;
  final int startedAtMs;
  final _PendingInteractionClaim claim;
  bool suppressSettle = false;
}

/// Immutable, single-use proof that a route observation may cite a tap cause.
class _PendingInteractionClaim {
  _PendingInteractionClaim({
    required this.tapEventId,
    required this.pointerId,
    required this.captureSessionId,
    required this.navigatorId,
    required this.routeInstanceId,
    required this.pointerGeneration,
  });

  final String tapEventId;
  final int pointerId;
  final String? captureSessionId;
  final String? navigatorId;
  final String? routeInstanceId;
  final int pointerGeneration;
  bool claimed = false;
  bool cancelled = false;

  bool get isEligible => !claimed && !cancelled;
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
    required this.routeEpoch,
    required this.startState,
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
  final int routeEpoch;
  final TugboatStateAnchor? startState;
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
    required this.freshness,
    required this.notBefore,
    required this.enqueuedAt,
    required this.context,
  });

  TugboatFrameTrigger trigger;
  bool force;
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
      context.compatibleWith(other.context);

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

/// The closed, privacy-safe capture result vocabulary.  These are deliberately
/// not exception names: a replay must not expose app content or platform error
/// strings just to explain why a frame was unavailable.
enum _CaptureOutcome {
  freshAccepted,
  exactContentReused,
  perceptualHashCoalesced,
  stateSignatureShortCircuit,
  screenshotBudgetSkip,
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
    _CaptureOutcome.stateSignatureShortCircuit =>
      'state_signature_short_circuit',
    _CaptureOutcome.screenshotBudgetSkip => 'screenshot_budget_skip',
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
    required this.stateAnchor,
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
  final TugboatStateAnchor? stateAnchor;
  final String? navigatorId;
  final String? routeInstanceId;
  final int? visualObservationGeneration;
  final Rect? boundaryLogicalRect;
  final int boundaryTransformGeneration;

  String? get stateSignature => stateAnchor?.signature;

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
        stateAnchor: stateAnchor,
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
    stateAnchor: stateAnchor,
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
    required this.completionStateAnchor,
    this.available = true,
  });

  final _CaptureRequestContext context;
  final int completedAtMs;
  final TugboatStateAnchor? completionStateAnchor;
  final bool available;

  _FrameProvenance unavailable() => _FrameProvenance(
    context: context,
    completedAtMs: completedAtMs,
    completionStateAnchor: completionStateAnchor,
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
    'requestStateSignature': context.stateSignature,
    'completionStateSignature': completionStateAnchor?.signature,
    if (context.stateAnchor != null)
      'requestStateAnchor': context.stateAnchor!.toJson(),
    if (completionStateAnchor != null)
      'completionStateAnchor': completionStateAnchor!.toJson(),
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
    this.stateAnchor,
    this.routeEventId,
    this.captureFailure,
    this.captureRequestId,
  });

  final _RouteCaptureOutcome outcome;
  final String? frameId;
  final TugboatStateAnchor? stateAnchor;
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

/// The one immutable observation used to write a `tap_settled` event.
///
/// A tap can outlive both a Navigator callback and another capture request.
/// Do not derive event fields from controller state after this is constructed:
/// that would pair an old frame with a later route/signature.
class _TapSettleObservation {
  const _TapSettleObservation({
    required this.routeEpoch,
    required this.route,
    required this.afterState,
    required this.afterFrame,
    required this.navigationOutcome,
    required this.captureOutcome,
    this.captureFailure,
    this.routeEventId,
    this.captureRequestId,
  });

  final int routeEpoch;
  final String? route;
  final TugboatStateAnchor? afterState;
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
  String? _currentNavigatorId;
  String? _currentRouteInstanceId;
  int _visualObservationGeneration = 0;
  int _boundaryTransformGeneration = 0;
  Rect? _lastObservedBoundaryRect;
  int _pointerGeneration = 0;
  final _NavigatorSurfaceRegistry _surfaces = _NavigatorSurfaceRegistry();
  TugboatStateAnchor? _currentStateAnchor;
  String? _latestFrameId;
  final Map<int, _PendingTap> _pendingTaps = {};
  final Map<int, _PendingInteractionClaim> _releasedInteractionClaims = {};
  final Map<String, String> _hashToFrameId = {};
  final Map<String, _FrameProvenance> _frameProvenance = {};
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
  _ScheduledCapture? _activeScheduledCapture;

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

  @visibleForTesting
  void debugSetCurrentRoute(String? route) {
    _currentRoute = route;
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
    Duration settleDelay = Duration.zero,
    String? relatedEventId,
  }) {
    final request = _requestCaptureCancellable(
      trigger: trigger,
      force: force,
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
      completionStateAnchor: _snapshotStateAnchor(_currentStateAnchor),
    );
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
      'frameId': _compatibleFrameFor(
        _captureContext(TugboatFrameTrigger.manual),
      ),
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
      captureDiagnostics: TugboatCaptureDiagnosticHealth(
        total: _captureDiagnosticTotal,
        lastOutcome: _lastCaptureDiagnosticOutcome,
        outcomes: Map.unmodifiable(_captureDiagnosticOutcomes),
      ),
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

    _cancelActiveTapSettles(cancellationReason);
    _cancelActiveRouteCapture(cancellationReason);
    _invalidateCaptureWork(cancellationReason);
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
    _cancelActiveTapSettles('session_replacement');
    _cancelActiveRouteCapture('session_replacement');
    _invalidateCaptureWork('session_replacement');
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
    _boundaryTransformGeneration = 0;
    _lastObservedBoundaryRect = null;
    _pointerGeneration = 0;
    _surfaces.clear();
    _currentStateAnchor = null;
    _latestFrameId = null;
    _pendingTaps.clear();
    _releasedInteractionClaims.clear();
    _scrollTrackers.clear();
    _activeGestures.clear();
    _hashToFrameId.clear();
    _frameProvenance.clear();
    _frameReuseObservations.clear();
    _lastCapturedStateSignature = null;
    _lastCaptureFailure = null;
    _emittedInventories.clear();
    _viewportSemantics.clear();
    _lastDHash = null;
    _captureDiagnosticOutcomes.clear();
    _captureDiagnosticTotal = 0;
    _lastCaptureDiagnosticOutcome = null;
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

  _CaptureFreshness _captureFreshnessFor(
    TugboatFrameTrigger trigger,
    bool force,
  ) {
    if (force ||
        trigger == TugboatFrameTrigger.initial ||
        trigger == TugboatFrameTrigger.lifecycle ||
        trigger == TugboatFrameTrigger.tap) {
      return _CaptureFreshness.freshPaint;
    }
    return _CaptureFreshness.reusable;
  }

  _CaptureRequestContext _captureContext(TugboatFrameTrigger trigger) {
    final anchor = _currentStateAnchor;
    final boundary = _observeCurrentBoundaryTransform();
    return _CaptureRequestContext(
      captureSessionId: _session?.id,
      routeEpoch: _routeEpoch,
      // Characterization harnesses can plant a state anchor without a real
      // Navigator callback. Its route remains valid evidence in that case.
      route: _currentRoute ?? anchor?.signatureParts['route'],
      trigger: trigger,
      requestedAtMs: atMs,
      stateAnchor: _snapshotStateAnchor(anchor),
      navigatorId: _currentNavigatorId,
      routeInstanceId: _currentRouteInstanceId,
      visualObservationGeneration: _visualObservationGeneration,
      boundaryLogicalRect: boundary.rect,
      boundaryTransformGeneration: boundary.generation,
    );
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

  TugboatStateAnchor? _snapshotStateAnchor(TugboatStateAnchor? anchor) {
    if (anchor == null) return null;
    return TugboatStateAnchor(
      schemaVersion: anchor.schemaVersion,
      actionableSummary: Map<String, int>.unmodifiable(
        anchor.actionableSummary,
      ),
      keyboardOpen: anchor.keyboardOpen,
      modalOpen: anchor.modalOpen,
      subLabel: anchor.subLabel,
      signature: anchor.signature,
      signatureConfidence: anchor.signatureConfidence,
      signatureParts: Map<String, String>.unmodifiable(anchor.signatureParts),
    );
  }

  TugboatStateAnchor? _stateObservedWithFrame(String? frameId) =>
      frameId == null ? null : _frameProvenance[frameId]?.completionStateAnchor;

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

  /// Emits exactly one bounded, sanitized resolution record for a logical
  /// request. This deliberately records a taxonomy value rather than the
  /// underlying exception so replay telemetry never contains app data.
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
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'capture_diagnostic',
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
        context.route ==
            (_currentRoute ?? _currentStateAnchor?.signatureParts['route']) &&
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
    if (_disposed ||
        _capturePaused ||
        _skipCapture ||
        _shouldSuppressFrameCapture) {
      _refreshStateAnchor();
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

    final now = _now();
    final delay = settleDelay ?? config.settleDelay;
    final notBefore = now.add(delay);
    final incoming = _ScheduledCapture(
      trigger: trigger,
      force: force,
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
            : outcome == _CaptureOutcome.stateSignatureShortCircuit
            ? 'state_signature'
            : null,
      );
    }
    if (_disposed ||
        _capturePaused ||
        _skipCapture ||
        _shouldSuppressFrameCapture ||
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

    final eligibleToSkip =
        freshness == _CaptureFreshness.reusable &&
        trigger != TugboatFrameTrigger.initial &&
        trigger != TugboatFrameTrigger.lifecycle &&
        config.screenshotBudget.skipEligibleWhenDegraded &&
        _screenshotBudget.shouldSkipEligible;
    final compatibleSkipFrame = eligibleToSkip
        ? _compatibleFrameFor(context)
        : null;
    if (compatibleSkipFrame != null) {
      _screenshotBudget.record(
        queueWaitMicros: queueWaitMicros,
        readbackMicros: 0,
        encodeMicros: 0,
        encodedBytes: 0,
        dropReason: 'budget',
      );
      _refreshStateAnchor();
      _maybeEmitSceneInventory();
      return _CaptureExecution(
        outcome: _CaptureOutcome.screenshotBudgetSkip,
        frameId: compatibleSkipFrame,
      );
    }

    final captureOverride = debugExecuteCapture;
    if (captureOverride != null) {
      _beginCapture();
      try {
        // Match the production capture path: refresh state before capture and
        // emit inventory after, so the override seam does not leave anchors
        // stale relative to real screenshot execution.
        _refreshStateAnchor();
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
      final attempt = await capturer.captureAttempt(
        lastDHash: _lastDHash,
        // A freshness-sensitive request needs a new logical observation even
        // when its pixels match. Reusing the old frame would also reuse its
        // old completion-state provenance.
        force: force || requiresFreshPaint,
        waitForFrame: true,
        requireFreshPaint: requiresFreshPaint,
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
      final result = attempt.result;
      if (result == null ||
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
      _refreshStateAnchor();
      final signature = _currentStateAnchor?.signature ?? '';
      if (!force &&
          !requiresFreshPaint &&
          trigger != TugboatFrameTrigger.initial &&
          signature.isNotEmpty &&
          signature == _lastCapturedStateSignature) {
        final compatible = _compatibleFrameFor(context);
        return _CaptureExecution(
          outcome: compatible == null
              ? _CaptureOutcome.noCompatibleFrame
              : _CaptureOutcome.stateSignatureShortCircuit,
          frameId: compatible,
          reuseReason: compatible == null ? null : 'state_signature',
        );
      }
      final activeSession = session;
      final completionStateAnchor = _snapshotStateAnchor(_refreshStateAnchor());

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
        if (result.dHash != null) {
          _lastDHash = result.dHash;
        }
        final compatible = _compatibleFrameFor(context);
        final reused = compatible == null
            ? null
            : _reuseCompatibleFrame(compatible, context, 'dhash');
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
        if (result.dHash != null) {
          _lastDHash = result.dHash;
        }
        if (signature.isNotEmpty) {
          _lastCapturedStateSignature = signature;
        }
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
        completionStateAnchor: completionStateAnchor,
      );
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

  void recordPointerDown(Offset position, {int pointer = 0}) {
    _releasedInteractionClaims.remove(pointer)?.cancelled = true;
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

    final attachmentContext = _captureContext(TugboatFrameTrigger.tap);
    final beforeFrame = _compatibleFrameFor(attachmentContext);
    final coordinateFrame =
        beforeFrame ?? _surfaceCompatibleFrameFor(attachmentContext);
    final unavailableReason = _unavailableAttachmentReason(attachmentContext);
    final captureCoordinate = _sampleCaptureCoordinate(
      position: position,
      frameId: coordinateFrame,
      context: attachmentContext,
    );
    final tapData = <String, Object?>{
      'x': position.dx,
      'y': position.dy,
      'captureCoordinate': captureCoordinate.toJson(),
      if (unavailableReason != null)
        'frameAttachment': {
          'before': 'unavailable',
          'reason': unavailableReason,
        },
      if (viewportResolution != null)
        'viewportSemanticResolution': viewportResolution.toJson(),
    };

    final beforeState = tapState;
    final eventId = _nextId('event');
    final claim = _PendingInteractionClaim(
      tapEventId: eventId,
      pointerId: pointer,
      captureSessionId: _session?.id,
      navigatorId: _currentNavigatorId,
      routeInstanceId: _currentRouteInstanceId,
      pointerGeneration: ++_pointerGeneration,
    );
    _pendingTaps[pointer] = _PendingTap(
      eventId: eventId,
      targetAnchor: target,
      beforeState: beforeState,
      beforeFrame: beforeFrame,
      startPosition: position,
      startedAtMs: atMs,
      claim: claim,
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

  void recordPointerCancel(Offset position, {int pointer = 0}) {
    final pending = _pendingTaps.remove(pointer);
    pending?.claim.cancelled = true;
    _releasedInteractionClaims.remove(pointer)?.cancelled = true;
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
      pending.claim.cancelled = true;
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

    // Gesture callbacks such as onTap run after the raw pointer-up listener
    // within the same event-loop turn. Keep the single-use claim alive only
    // through that turn so Navigator observers can attribute the transition
    // without allowing later automatic navigation to borrow the tap.
    _releasedInteractionClaims[pointer] = pending.claim;
    scheduleMicrotask(() {
      if (identical(_releasedInteractionClaims[pointer], pending.claim)) {
        _releasedInteractionClaims.remove(pointer);
      }
    });

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
      final initialRouteCapture =
          routeCaptureAtPointerUp?.change.causeEventId == pending.eventId
          ? routeCaptureAtPointerUp
          : null;
      // Give a callback immediately after pointer-up the same settle boundary.
      if (initialRouteCapture == null && config.settleDelay > Duration.zero) {
        final deadline = _scheduleDelay(config.settleDelay);
        work.attachDeadlineCancellation(deadline.cancel);
        await deadline.done;
      }
      if (!_isActiveTapSettle(work)) return;
      // A tap may only inherit a route barrier that was causally claimed by
      // that exact tap. In particular, an automatic navigation that starts
      // while this tap is waiting to settle is independent evidence: joining
      // it would incorrectly copy its destination frame and route event ID
      // onto the tap.
      final currentRouteCapture = _activeRouteCapture;
      final routeCapture =
          initialRouteCapture ??
          (currentRouteCapture?.change.causeEventId == pending.eventId
              ? currentRouteCapture
              : null);
      _TapSettleObservation observation;
      if (routeCapture != null) {
        final routeBarrier = await _awaitRouteCaptureBarrier(
          routeCapture,
          expectedCauseEventId: pending.eventId,
        );
        if (!_isActiveTapSettle(work)) return;
        observation = _tapObservationFromRouteBarrier(routeBarrier);
      } else {
        final requestedRouteEpoch = _routeEpoch;
        final requestedRoute = _currentRoute;
        final semanticAfterState = _snapshotStateAnchor(_refreshStateAnchor());
        final capture = _requestCaptureCancellable(
          trigger: TugboatFrameTrigger.tap,
          settleDelay: Duration.zero,
          relatedEventId: pending.eventId,
        );
        work.attachCaptureCancellation((reason) => capture.cancel(reason));
        final captureResolution = await capture.resolution;
        final afterFrame = captureResolution.frameId;
        if (!_isActiveTapSettle(work)) return;
        final provenance = afterFrame == null
            ? null
            : _frameProvenance[afterFrame];
        final compatibleFrame =
            afterFrame != null &&
            provenance != null &&
            provenance.context.routeEpoch == requestedRouteEpoch &&
            provenance.context.route == requestedRoute;
        final replacementRoute = _activeRouteCapture;
        if (!compatibleFrame &&
            replacementRoute != null &&
            replacementRoute.epoch != requestedRouteEpoch &&
            replacementRoute.change.causeEventId == pending.eventId) {
          final routeBarrier = await _awaitRouteCaptureBarrier(
            replacementRoute,
            expectedCauseEventId: pending.eventId,
          );
          if (!_isActiveTapSettle(work)) return;
          observation = _tapObservationFromRouteBarrier(routeBarrier);
        } else {
          observation = _TapSettleObservation(
            routeEpoch: requestedRouteEpoch,
            route: requestedRoute,
            afterState: compatibleFrame
                ? _stateObservedWithFrame(afterFrame)
                : semanticAfterState,
            afterFrame: compatibleFrame ? afterFrame : null,
            navigationOutcome: 'same_route',
            captureOutcome: compatibleFrame ? 'captured' : 'failed',
            captureFailure: compatibleFrame
                ? null
                : captureResolution.outcome.wireName,
            captureRequestId: captureResolution.requestId,
          );
        }
      }
      Future<void> writeSettle() async {
        if (!_isActiveTapSettle(work)) return;
        final beforeState = pending.beforeState;
        final beforeFrame = pending.beforeFrame;
        final tapEventId = pending.eventId;
        final tapTargetAnchor = pending.targetAnchor;
        // Never read mutable controller state here: later route/capture work
        // may have advanced while this task waited on the serialized queue.
        final afterState = observation.afterState;
        final afterFrame = observation.afterFrame;
        final result = _computeTapSettleResult(
          beforeState: beforeState,
          afterState: afterState,
          beforeFrame: beforeFrame,
          afterFrame: afterFrame,
          navigationOutcome: observation.navigationOutcome,
          degraded: observation.isDegraded,
        );
        final beforeSignature = beforeState?.signature;
        final afterSignature = afterState?.signature;
        final semanticAvailable =
            beforeSignature?.isNotEmpty == true &&
            afterSignature?.isNotEmpty == true;
        final semanticChanged = semanticAvailable
            ? beforeSignature != afterSignature
            : null;
        final beforeContentHash = beforeFrame == null
            ? null
            : _frameContentHash(beforeFrame);
        final afterContentHash = afterFrame == null
            ? null
            : _frameContentHash(afterFrame);
        final visualAvailable =
            beforeContentHash != null && afterContentHash != null;
        final visualChanged = visualAvailable
            ? beforeContentHash != afterContentHash
            : null;

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
            data: {
              'x': position.dx,
              'y': position.dy,
              'settleObservation': {
                'version': 1,
                'routeEpoch': observation.routeEpoch,
                if (observation.route != null) 'route': observation.route,
                'navigationOutcome': observation.navigationOutcome,
                'captureOutcome': observation.captureOutcome,
                if (observation.captureFailure != null)
                  'captureFailure': observation.captureFailure,
                if (observation.routeEventId != null)
                  'routeEventId': observation.routeEventId,
                if (observation.captureRequestId != null)
                  'captureRequestId': observation.captureRequestId,
                'semantic': {
                  'changed': semanticChanged,
                  'evidence': semanticAvailable
                      ? 'state_signature'
                      : 'unavailable',
                  'reason': semanticChanged == null
                      ? 'unavailable'
                      : semanticChanged
                      ? 'state_signature_changed'
                      : 'same_signature',
                },
                'visual': {
                  'changed': visualChanged,
                  'evidence': visualAvailable ? 'content_hash' : 'unavailable',
                  'reason': visualChanged == null
                      ? 'unavailable'
                      : visualChanged
                      ? 'frame_changed'
                      : 'same_frame',
                },
              },
              if (afterFrame == null)
                'frameAttachment': {
                  'after': 'unavailable',
                  'reason':
                      observation.captureFailure ?? observation.captureOutcome,
                },
            },
          ),
        );
        _maybeEmitStateChange(
          beforeState: beforeState,
          afterState: afterState,
          beforeFrame: beforeFrame,
          afterFrame: afterFrame,
        );
        if (!_disposed) notifyListeners();
      }

      // Route barriers may time out while the ordinary event queue is blocked.
      // Publish that one degraded, frame-less observation immediately rather
      // than letting it be replaced by unrelated later route state.
      if (observation.isDegraded) {
        try {
          await writeSettle();
        } catch (error, stackTrace) {
          debugPrint('[tugboat] tap_settled failed: $error\n$stackTrace');
        }
      } else {
        await _enqueue('tap_settled', writeSettle);
      }
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

  _TapSettleObservation _tapObservationFromRouteBarrier(
    ({_RouteCaptureWork work, _RouteCaptureResult result}) routeBarrier,
  ) {
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
      afterState: validFrame
          ? _stateObservedWithFrame(frameId)
          : routeResult.stateAnchor,
      afterFrame: validFrame ? frameId : null,
      navigationOutcome: validFrame ? 'navigated' : 'navigation_unavailable',
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

  TugboatInteractionResult _computeTapSettleResult({
    required TugboatStateAnchor? beforeState,
    required TugboatStateAnchor? afterState,
    required String? beforeFrame,
    required String? afterFrame,
    String navigationOutcome = 'same_route',
    bool degraded = false,
  }) {
    if (degraded) return TugboatInteractionResult.unknown;
    if (navigationOutcome == 'navigated') {
      return TugboatInteractionResult.navigated;
    }
    final beforeSig = beforeState?.signature ?? '';
    final afterSig = afterState?.signature ?? '';
    if (beforeSig.isNotEmpty && afterSig.isNotEmpty && beforeSig != afterSig) {
      return TugboatInteractionResult.changed;
    }
    if (_framesVisuallyDifferent(beforeFrame, afterFrame)) {
      return TugboatInteractionResult.changed;
    }
    final beforeHash = beforeFrame == null
        ? null
        : _frameContentHash(beforeFrame);
    final afterHash = afterFrame == null ? null : _frameContentHash(afterFrame);
    if (beforeSig.isNotEmpty &&
        afterSig.isNotEmpty &&
        beforeHash != null &&
        afterHash != null) {
      return TugboatInteractionResult.noVisibleChange;
    }
    return TugboatInteractionResult.unknown;
  }

  bool _framesVisuallyDifferent(String? beforeFrame, String? afterFrame) {
    if (beforeFrame == null || afterFrame == null) return false;
    final beforeHash = _frameContentHash(beforeFrame);
    final afterHash = _frameContentHash(afterFrame);
    return beforeHash != null && afterHash != null && beforeHash != afterHash;
  }

  String? _frameContentHash(String frameId) {
    return _session?.frameById(frameId)?.contentHash;
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
    final attachmentContext = _captureContext(TugboatFrameTrigger.scroll);
    final beforeFrame = _compatibleFrameFor(attachmentContext);
    final unavailableReason = _unavailableAttachmentReason(attachmentContext);
    final startEventId = _nextId('event');
    final pageStart = metrics is PageMetrics ? metrics.page : null;

    final tracker = _ScrollTracker(
      scrollableElement: scrollableElement,
      startEventId: startEventId,
      startedAtMs: atMs,
      startOffset: metrics.pixels,
      routeEpoch: _routeEpoch,
      startState: _snapshotStateAnchor(_currentStateAnchor),
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
        data: {
          ..._scrollEventData(metrics: metrics, depth: depth, tracker: tracker),
          if (unavailableReason != null)
            'frameAttachment': {
              'before': 'unavailable',
              'reason': unavailableReason,
            },
        },
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
      if (tracker.routeEpoch != _routeEpoch) {
        // A navigator transition won the race with pointer-up. Capturing now
        // would attribute the destination's pixels to the completed scroll on
        // the previous route, so retain the scroll boundary as explicitly
        // degraded evidence instead of queuing a cross-route capture.
        _addEvent(
          TugboatEvent(
            id: _nextId('event'),
            atMs: atMs,
            type: 'scroll_end',
            stateAnchor: tracker.startState,
            targetAnchor: tracker.targetAnchor,
            beforeFrame: tracker.beforeFrame,
            relatedEventId: tracker.startEventId,
            data: {
              ..._scrollEventData(
                metrics: metrics,
                depth: tracker.depth,
                tracker: tracker,
                endOffset: metrics.pixels,
                durationMs: atMs - tracker.startedAtMs,
                overscrollCount: tracker.overscrollCount,
              ),
              'captureOutcome': 'superseded_route_epoch',
              'frameAttachment': {
                'after': 'unavailable',
                'reason': 'superseded_route_epoch',
              },
            },
          ),
        );
        if (!_disposed) notifyListeners();
        return;
      }
      final afterCapture = _requestCaptureCancellable(
        trigger: TugboatFrameTrigger.scroll,
        force: true,
        relatedEventId: tracker.startEventId,
      );
      final afterResolution = await afterCapture.resolution;
      final afterFrame = afterResolution.frameId;
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
          stateAnchor:
              _stateObservedWithFrame(afterFrame) ?? _refreshStateAnchor(),
          targetAnchor: tracker.targetAnchor,
          beforeFrame: tracker.beforeFrame,
          afterFrame: afterFrame,
          relatedEventId: tracker.startEventId,
          data: {
            ..._scrollEventData(
              metrics: metrics,
              depth: tracker.depth,
              tracker: tracker,
              endOffset: metrics.pixels,
              durationMs: atMs - tracker.startedAtMs,
              overscrollCount: tracker.overscrollCount,
            ),
            'captureRequestId': afterResolution.requestId,
            'captureOutcome': afterResolution.outcome.wireName,
            if (afterFrame == null)
              'frameAttachment': {
                'after': 'unavailable',
                'reason': afterResolution.outcome.wireName,
              },
          },
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
          (_shouldSuppressFrameCapture ? Duration.zero : config.settleDelay),
    );
    _activeRouteCaptures[captureKey] = work;
    _latestRouteCaptureKey = captureKey;
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
      _skipCapture = false;
      return;
    }
    final active = List<_RouteCaptureWork>.from(_activeRouteCaptures.values);
    _activeRouteCaptures.clear();
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
    final observedState = _snapshotStateAnchor(_refreshStateAnchor());
    final routeEventId = _nextId('event');
    // This must not enqueue behind the blocked task that caused the timeout.
    // Dart's single isolate means the session mutation is still atomic with
    // respect to the next event-loop turn.
    _addEvent(
      TugboatEvent(
        id: routeEventId,
        atMs: atMs,
        type: 'route_change',
        stateAnchor: observedState,
        result: TugboatInteractionResult.unknown,
        data: {
          if (change.previousRoute != null) 'fromRoute': change.previousRoute,
          if (change.destinationRoute != null) 'route': change.destinationRoute,
          'navigation': change.navigation,
          'captureOutcome': 'timed_out',
          ...change.ownershipData(),
        },
      ),
    );
    work.complete(
      _RouteCaptureResult(
        _RouteCaptureOutcome.timedOut,
        stateAnchor: observedState,
        routeEventId: routeEventId,
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
    TugboatStateAnchor? observedState;
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
      _refreshStateAnchor();
      final capture = _requestCaptureCancellable(
        trigger: TugboatFrameTrigger.route,
        force: true,
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
        observedState = _snapshotStateAnchor(_currentStateAnchor);
        routeEventId = _nextId('event');
        _addEvent(
          TugboatEvent(
            id: routeEventId,
            atMs: atMs,
            type: 'route_change',
            stateAnchor: observedState,
            result: TugboatInteractionResult.navigated,
            data: {
              if (change.previousRoute != null)
                'fromRoute': change.previousRoute,
              if (change.destinationRoute != null)
                'route': change.destinationRoute,
              'navigation': change.navigation,
              'captureOutcome': 'failed',
              if (captureResult.captureFailure != null)
                'captureFailure': captureResult.captureFailure,
              if (captureRequestId != null)
                'captureRequestId': captureRequestId,
              ...change.ownershipData(),
            },
          ),
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
      final previousRoute = change.previousRoute;
      final destinationRoute = change.destinationRoute;
      observedState =
          _stateObservedWithFrame(afterFrame) ?? _currentStateAnchor;
      routeEventId = _nextId('event');
      _addEvent(
        TugboatEvent(
          id: routeEventId,
          atMs: atMs,
          type: 'route_change',
          stateAnchor: observedState,
          afterFrame: afterFrame,
          result: TugboatInteractionResult.navigated,
          data: {
            if (previousRoute != null) 'fromRoute': previousRoute,
            if (destinationRoute != null) 'route': destinationRoute,
            'navigation': change.navigation,
            if (captureRequestId != null) 'captureRequestId': captureRequestId,
            if (outcome == _RouteCaptureOutcome.failed)
              'captureOutcome': 'failed',
            if (outcome == _RouteCaptureOutcome.failed &&
                captureResult.captureFailure != null)
              'captureFailure': captureResult.captureFailure,
            ...change.ownershipData(),
          },
        ),
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
          stateAnchor: observedState,
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
    final causeEventId = _tryClaimInteractionCause(
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
      navigationOrigin: causeEventId == null
          ? 'automatic_or_unknown'
          : 'interaction',
      causeEventId: causeEventId,
    );
  }

  /// Observer-time single-use claim. Returns the tap event ID only when exactly
  /// one unambiguous active pointer is eligible for this navigator/session.
  String? _tryClaimInteractionCause({String? navigatorId}) {
    final eligible = <_PendingInteractionClaim>[];
    for (final pending in _pendingTaps.values) {
      if (pending.suppressSettle) continue;
      final claim = pending.claim;
      if (!claim.isEligible) continue;
      if (claim.captureSessionId != _session?.id) continue;
      eligible.add(claim);
    }
    for (final claim in _releasedInteractionClaims.values) {
      if (!claim.isEligible) continue;
      if (claim.captureSessionId != _session?.id) continue;
      eligible.add(claim);
    }
    if (eligible.length != 1) return null;
    final claim = eligible.single;
    if (navigatorId != null &&
        claim.navigatorId != null &&
        claim.navigatorId != navigatorId) {
      return null;
    }
    claim.claimed = true;
    return claim.tapEventId;
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
    // must not replace or suppress inventory; maps are an exploration companion.
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
