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
import 'screenshot_capture_backend.dart';
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
  String get wireName => _captureOutcomeWireNames[index];
}

const _captureOutcomeWireNames = <String>[
  'fresh_accepted',
  'exact_content_reused',
  'perceptual_hash_coalesced',
  'paint_generation_unchanged',
  'screenshot_budget_skip',
  'capture_pressure_drop',
  'no_frame_available',
  'no_compatible_frame',
  'paint_readiness_timeout',
  'boundary_unavailable',
  'capture_processing_failed',
  'cancelled',
  'superseded_route_epoch',
];

const _paintReadinessFailures = <ScreenshotCaptureFailure>{
  ScreenshotCaptureFailure.paintTimedOut,
  ScreenshotCaptureFailure.paintNotAdvanced,
};

const _boundaryFailures = <ScreenshotCaptureFailure>{
  ScreenshotCaptureFailure.boundaryDetached,
  ScreenshotCaptureFailure.boundaryUnavailable,
  ScreenshotCaptureFailure.boundaryReplaced,
  ScreenshotCaptureFailure.layoutUnavailable,
};

const _processingFailures = <ScreenshotCaptureFailure>{
  ScreenshotCaptureFailure.readbackFailed,
  ScreenshotCaptureFailure.maskFailed,
  ScreenshotCaptureFailure.encodingFailed,
};

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
    this.backendTrace,
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
  final ScreenshotBackendTrace? backendTrace;
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
    this.backendTrace,
  });

  final _CaptureOutcome outcome;
  final String? frameId;
  final ScreenshotCaptureFailure? failure;
  final String? cancellationReason;
  final String? reuseReason;
  final ScreenshotBackendTrace? backendTrace;
}

/// The outcome of the physical capture retry phase. It separates a terminal
/// execution from an accepted screenshot attempt without using an untyped
/// nullable pair at the capture boundary.
class _PhysicalCaptureAttemptResolution {
  const _PhysicalCaptureAttemptResolution.execution(this.execution)
    : attempt = null,
      result = null;

  const _PhysicalCaptureAttemptResolution.captured(this.attempt, this.result)
    : execution = null;

  final _CaptureExecution? execution;
  final ScreenshotCaptureAttempt? attempt;
  final ScreenshotCaptureResult? result;
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
    required this.identity,
    required this.transitionDuration,
    this.overlayKind = TugboatOverlayKind.page,
  });

  final _RouteNavigationKind kind;
  final String? routeName;
  final TugboatRouteIdentity identity;
  final Duration transitionDuration;
  final String overlayKind;
}

class _RouteSurfaceRecord {
  const _RouteSurfaceRecord({
    required this.instanceId,
    required this.route,
    required this.routeNamed,
    required this.overlayKind,
    required this.navigatorId,
  });

  final String instanceId;
  final String route;
  final bool routeNamed;
  final String overlayKind;
  final String navigatorId;

  Map<String, Object?> toStackEntry() => {
    'routeInstanceId': instanceId,
    'route': route,
    'routeNamed': routeNamed,
    'overlayKind': overlayKind,
    'navigatorId': navigatorId,
  };
}

class _RoutePresentationParent {
  const _RoutePresentationParent({
    this.presentedOverRoute,
    this.presentedOverRouteInstanceId,
    this.presentedOverOverlayKind,
    this.hostPageRoute,
    this.hostPageRouteInstanceId,
  });

  final String? presentedOverRoute;
  final String? presentedOverRouteInstanceId;
  final String? presentedOverOverlayKind;
  final String? hostPageRoute;
  final String? hostPageRouteInstanceId;
}

/// A resolved, visible navigation: what to record and how to update
/// [TugboatReplayController._currentRoute].
class _VisibleRouteChange {
  const _VisibleRouteChange({
    required this.previousRoute,
    required this.destinationRoute,
    required this.navigation,
    required this.updatesRoute,
    required this.routeType,
    required this.routeNamed,
    this.routeName,
    this.fromRouteName,
    this.fromRouteType,
    this.fromRouteNamed,
    this.navigatorId,
    this.parentNavigatorId,
    this.routeInstanceId,
    this.fromRouteInstanceId,
    this.stackRevision = 0,
    this.overlayKind = TugboatOverlayKind.page,
    this.visualObservationGeneration = 0,
    this.navigationOrigin = 'automatic_or_unknown',
    this.causeEventId,
    this.causeTargetFingerprint,
    this.causeGesture,
    this.interactionAttribution,
    this.presentedOverRoute,
    this.presentedOverRouteInstanceId,
    this.presentedOverOverlayKind,
    this.hostPageRoute,
    this.hostPageRouteInstanceId,
    this.routeStack = const <Map<String, Object?>>[],
    this.routeStackTruncated = false,
  });

  final String? previousRoute;
  final String? destinationRoute;
  final String navigation;
  final bool updatesRoute;
  final String? routeName;
  final String routeType;
  final bool routeNamed;
  final String? fromRouteName;
  final String? fromRouteType;
  final bool? fromRouteNamed;
  final String? navigatorId;
  final String? parentNavigatorId;
  final String? routeInstanceId;
  final String? fromRouteInstanceId;
  final int stackRevision;
  final String overlayKind;
  final int visualObservationGeneration;
  final String navigationOrigin;
  final String? causeEventId;
  final String? causeTargetFingerprint;
  final String? causeGesture;

  /// Wire form is [InteractionAttribution.claimWireName] (`same_turn` /
  /// `delayed_likely`) when a claim succeeds.
  final InteractionAttribution? interactionAttribution;
  final String? presentedOverRoute;
  final String? presentedOverRouteInstanceId;
  final String? presentedOverOverlayKind;
  final String? hostPageRoute;
  final String? hostPageRouteInstanceId;
  final List<Map<String, Object?>> routeStack;
  final bool routeStackTruncated;

  bool get bypassesExplorationSuppression =>
      causeEventId != null || overlayKind != TugboatOverlayKind.page;

  Map<String, Object?> ownershipData() => {
    ..._routeIdentityData(),
    ..._routeSurfaceData(),
    ..._routeCauseData(),
    ..._routePresentationData(),
  };

  Map<String, Object?> _routeIdentityData() => {
    if (routeName != null) 'routeName': routeName,
    'routeType': routeType,
    'routeNamed': routeNamed,
    if (fromRouteName != null) 'fromRouteName': fromRouteName,
    if (fromRouteType != null) 'fromRouteType': fromRouteType,
    if (fromRouteNamed != null) 'fromRouteNamed': fromRouteNamed,
  };

  Map<String, Object?> _routeSurfaceData() => {
    if (navigatorId != null) 'navigatorId': navigatorId,
    if (parentNavigatorId != null) 'parentNavigatorId': parentNavigatorId,
    if (routeInstanceId != null) 'routeInstanceId': routeInstanceId,
    if (fromRouteInstanceId != null) 'fromRouteInstanceId': fromRouteInstanceId,
    'stackRevision': stackRevision,
    'overlayKind': overlayKind,
    'visualObservationGeneration': visualObservationGeneration,
    'navigationOrigin': navigationOrigin,
  };

  Map<String, Object?> _routeCauseData() => {
    if (causeEventId != null) 'causeEventId': causeEventId,
    if (causeEventId != null) 'causedByInteractionId': causeEventId,
    if (causeTargetFingerprint != null)
      'causeTargetFingerprint': causeTargetFingerprint,
    if (causeGesture != null) 'causeGesture': causeGesture,
    if (interactionAttribution != null)
      'interactionAttribution': interactionAttribution!.claimWireName,
  };

  Map<String, Object?> _routePresentationData() => {
    if (presentedOverRoute != null) 'presentedOverRoute': presentedOverRoute,
    if (presentedOverRouteInstanceId != null)
      'presentedOverRouteInstanceId': presentedOverRouteInstanceId,
    if (presentedOverOverlayKind != null)
      'presentedOverOverlayKind': presentedOverOverlayKind,
    if (hostPageRoute != null) 'hostPageRoute': hostPageRoute,
    if (hostPageRouteInstanceId != null)
      'hostPageRouteInstanceId': hostPageRouteInstanceId,
    if (routeStack.isNotEmpty) 'routeStack': routeStack,
    if (routeStackTruncated) 'routeStackTruncated': true,
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
  final Map<String, _RouteSurfaceRecord> _records =
      <String, _RouteSurfaceRecord>{};
  int _navigatorSeq = 0;
  int _routeSeq = 0;

  void clear() {
    _navigatorIds.clear();
    _stacks.clear();
    _parentByNavigator.clear();
    _records.clear();
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

  void remember({
    required String instanceId,
    required String navigatorId,
    required TugboatRouteIdentity identity,
    required String overlayKind,
  }) {
    final route = identity.route;
    if (route == null || route.isEmpty) return;
    _records[instanceId] = _RouteSurfaceRecord(
      instanceId: instanceId,
      route: route,
      routeNamed: identity.routeNamed,
      overlayKind: overlayKind,
      navigatorId: navigatorId,
    );
  }

  _RoutePresentationParent? presentationParent({
    required String navigatorId,
    required String instanceId,
    required String overlayKind,
    required bool isPush,
  }) {
    if (!isPush || overlayKind == TugboatOverlayKind.page) return null;
    final presented = _presentedOver(navigatorId, instanceId);
    final host = _hostPage(navigatorId);
    if (presented == null && host == null) return null;
    return _RoutePresentationParent(
      presentedOverRoute: presented?.route,
      presentedOverRouteInstanceId: presented?.instanceId,
      presentedOverOverlayKind: presented?.overlayKind,
      hostPageRoute: host?.route,
      hostPageRouteInstanceId: host?.instanceId,
    );
  }

  List<Map<String, Object?>> stackSnapshot(String navigatorId) {
    final stack = _stacks[navigatorId];
    if (stack == null || stack.isEmpty) return const [];
    final start = _stackSnapshotStart(stack.length);
    final entries = <Map<String, Object?>>[];
    for (var i = start; i < stack.length; i++) {
      final record = _records[stack[i]];
      if (record != null) entries.add(record.toStackEntry());
    }
    return entries;
  }

  bool stackTruncated(String navigatorId) =>
      (_stacks[navigatorId]?.length ?? 0) > tugboatRouteStackMaxEntries;

  _RouteSurfaceRecord? _presentedOver(String navigatorId, String instanceId) {
    final stack = _stacks[navigatorId];
    if (stack == null || stack.length < 2 || stack.last != instanceId) {
      return null;
    }
    return _records[stack[stack.length - 2]];
  }

  _RouteSurfaceRecord? _hostPage(String navigatorId) {
    final local = _pageOnStack(navigatorId, skipTop: true);
    if (local != null) return local;
    var parentId = _parentByNavigator[navigatorId];
    while (parentId != null) {
      final page = _pageOnStack(parentId, skipTop: false);
      if (page != null) return page;
      parentId = _parentByNavigator[parentId];
    }
    return null;
  }

  _RouteSurfaceRecord? _pageOnStack(
    String navigatorId, {
    required bool skipTop,
  }) {
    final stack = _stacks[navigatorId];
    if (stack == null || stack.isEmpty) return null;
    final lastIndex = skipTop ? stack.length - 2 : stack.length - 1;
    for (var i = lastIndex; i >= 0; i--) {
      final record = _records[stack[i]];
      if (record != null && record.overlayKind == TugboatOverlayKind.page) {
        return record;
      }
    }
    return null;
  }

  static int _stackSnapshotStart(int length) =>
      length > tugboatRouteStackMaxEntries
      ? length - tugboatRouteStackMaxEntries
      : 0;

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
  TugboatLocaleInfo? _currentLocale;

  int _id = 0;
  String? _currentRoute;
  TugboatRouteIdentity? _currentRouteIdentity;
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
      screenshotCaptureBackend: config.screenshotCaptureBackend,
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

  void start(Size viewport, String platform, {TugboatLocaleInfo? locale}) {
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
    final effectiveLocale = locale ?? _currentLocale;
    _currentLocale = effectiveLocale;
    _session = TugboatSession(
      id: 'session-${DateTime.now().microsecondsSinceEpoch}',
      startedAt: DateTime.now(),
      platform: platform,
      viewport: TugboatRect(0, 0, viewport.width, viewport.height),
      appInfo: config.appInfo ?? config.collector?.appInfo,
      locale: effectiveLocale,
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
      locale: _currentLocale,
    );
  }

  /// Records the active app locale as evidence without changing identity.
  void recordLocale(TugboatLocaleInfo locale) {
    if (locale == _currentLocale) return;
    final previous = _currentLocale;
    _currentLocale = locale;
    final session = _session;
    if (session == null) return;
    session.locale = locale;
    _addEvent(
      TugboatEvent(
        id: _nextId('event'),
        atMs: atMs,
        type: 'locale_changed',
        stream: TugboatEventStream.evidence,
        locale: locale,
        data: {
          if (previous != null) 'previousLocale': previous.toJson(),
          'locale': locale.toJson(),
        },
      ),
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
          ...?resolution.backendTrace?.toDiagnosticFields(),
        },
      ),
    );
  }

  _CaptureOutcome _diagnosticOutcomeForFailure(
    ScreenshotCaptureFailure? failure,
  ) {
    if (_paintReadinessFailures.contains(failure)) {
      return _CaptureOutcome.paintReadinessTimeout;
    }
    if (_boundaryFailures.contains(failure)) {
      return _CaptureOutcome.boundaryUnavailable;
    }
    if (_processingFailures.contains(failure)) {
      return _CaptureOutcome.captureProcessingFailed;
    }
    if (failure == ScreenshotCaptureFailure.cancelled) {
      return _CaptureOutcome.cancelled;
    }
    return _CaptureOutcome.noFrameAvailable;
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
    if (_requestCaptureIsSuppressed(bypassesExplorationSuppression)) {
      return _completeRejectedCaptureRequest(
        waiter,
        _cancelledCaptureExecution(_captureSuppressionReason()),
      );
    }

    if (dropWhenBusy && _captureQueueIsBusy) {
      _recordCapturePressureDrop();
      return _completeRejectedCaptureRequest(
        waiter,
        const _CaptureExecution(
          outcome: _CaptureOutcome.capturePressureDrop,
          cancellationReason: 'capture_pressure',
        ),
        emitSceneInventory: false,
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

    _queueScheduledCapture(incoming);

    _ensureCapturePumpScheduled();
    return (
      done: waiter.completer.future.then((value) => value.frameId),
      resolution: waiter.completer.future,
      cancel: ([String reason = 'manual']) =>
          _cancelCaptureWaiter(waiter, reason),
    );
  }

  bool _requestCaptureIsSuppressed(bool bypass) =>
      _disposed ||
      _capturePaused ||
      _skipCapture ||
      _explorationCaptureIsSuppressed(bypass);

  bool get _captureQueueIsBusy => _captureInFlight || _scheduledCapture != null;

  ({
    Future<String?> done,
    Future<_CaptureResolution> resolution,
    void Function([String reason]) cancel,
  })
  _completeRejectedCaptureRequest(
    _CaptureWaiter waiter,
    _CaptureExecution execution, {
    bool emitSceneInventory = true,
  }) {
    if (emitSceneInventory) _maybeEmitSceneInventory();
    _completeCaptureWaiter(
      waiter,
      executionId: _nextId('capture_execution'),
      execution: execution,
    );
    return (
      done: waiter.completer.future.then((value) => value.frameId),
      resolution: waiter.completer.future,
      cancel: ([String reason = 'manual']) {},
    );
  }

  void _recordCapturePressureDrop() => _screenshotBudget.record(
    queueWaitMicros: 0,
    readbackMicros: 0,
    encodeMicros: 0,
    encodedBytes: 0,
    dropReason: 'capture_pressure',
  );

  void _queueScheduledCapture(_ScheduledCapture incoming) {
    final scheduled = _scheduledCapture;
    if (scheduled == null) {
      _scheduledCapture = incoming;
      return;
    }
    var tail = scheduled;
    while (tail.next != null) {
      tail = tail.next!;
    }
    if (tail.canAbsorb(incoming)) {
      tail.absorb(incoming);
    } else {
      tail.next = incoming;
    }
  }

  void _cancelCaptureWaiter(_CaptureWaiter waiter, String reason) {
    _removeCaptureWaiterFromQueue(waiter);
    _activeScheduledCapture?.waiters.remove(waiter);
    _completeCaptureWaiter(
      waiter,
      executionId: _nextId('capture_execution'),
      execution: _cancelledCaptureExecution(reason),
    );
  }

  void _removeCaptureWaiterFromQueue(_CaptureWaiter waiter) {
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
      backendTrace: execution.backendTrace,
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
      final schedulerWait = _scheduledCaptureWait(scheduled);
      if (schedulerWait != null) await _delay(schedulerWait);
      if (_disposed) break;
      if (_captureInFlight) {
        await _waitForCaptureIdle();
        continue;
      }
      if (!_canRunScheduledCapture(scheduled)) continue;
      final execution = await _runScheduledCapture(scheduled);
      _completeScheduledCaptureWaiters(scheduled, execution);
    }
  }

  Duration? _scheduledCaptureWait(_ScheduledCapture scheduled) {
    final wait = scheduled.notBefore.difference(_now());
    return wait > Duration.zero ? wait : null;
  }

  bool _canRunScheduledCapture(_ScheduledCapture scheduled) =>
      !_disposed &&
      identical(scheduled, _scheduledCapture) &&
      !_captureInFlight;

  Future<_CaptureExecution> _runScheduledCapture(
    _ScheduledCapture scheduled,
  ) async {
    final queueWaitMicros = _now()
        .difference(scheduled.enqueuedAt)
        .inMicroseconds;
    _scheduledCapture = scheduled.next;
    scheduled.next = null;
    _activeScheduledCapture = scheduled;
    try {
      return await _executeCapture(
        trigger: scheduled.trigger,
        force: scheduled.force,
        bypassExplorationSuppression: scheduled.bypassesExplorationSuppression,
        freshness: scheduled.freshness,
        context: scheduled.context.withTrigger(scheduled.trigger),
        queueWaitMicros: queueWaitMicros,
      );
    } catch (error, stackTrace) {
      debugPrint('[tugboat] capture failed: $error\n$stackTrace');
      return const _CaptureExecution(
        outcome: _CaptureOutcome.captureProcessingFailed,
      );
    }
  }

  void _completeScheduledCaptureWaiters(
    _ScheduledCapture scheduled,
    _CaptureExecution execution,
  ) {
    final executionId = _nextId('capture_execution');
    for (final waiter in scheduled.waiters) {
      _completeCaptureWaiter(
        waiter,
        executionId: executionId,
        execution: _executionForCaptureWaiter(execution, waiter),
      );
    }
    if (identical(_activeScheduledCapture, scheduled)) {
      _activeScheduledCapture = null;
    }
  }

  _CaptureExecution _executionForCaptureWaiter(
    _CaptureExecution execution,
    _CaptureWaiter waiter,
  ) {
    final frameId = execution.frameId;
    final compatible =
        frameId != null && _isFrameCompatible(frameId, waiter.context);
    return _CaptureExecution(
      outcome: compatible
          ? execution.outcome
          : _incompatibleWaiterOutcome(execution, waiter),
      frameId: compatible ? frameId : null,
      failure: execution.failure,
      cancellationReason: execution.cancellationReason,
      reuseReason: execution.reuseReason,
      backendTrace: execution.backendTrace,
    );
  }

  _CaptureOutcome _incompatibleWaiterOutcome(
    _CaptureExecution execution,
    _CaptureWaiter waiter,
  ) {
    if (execution.frameId == null) return execution.outcome;
    return _unavailableAttachmentReason(waiter.context) == 'no_frame_available'
        ? _CaptureOutcome.noFrameAvailable
        : _CaptureOutcome.noCompatibleFrame;
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
    final debugExecution = _takeDebugCaptureExecution();
    if (debugExecution != null) return debugExecution;
    if (_captureExecutionIsSuppressed(bypassExplorationSuppression)) {
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

    final eligibleToSkip = _isEligibleForBudgetSkip(freshness, trigger);
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
      return _executeCaptureOverride(
        captureOverride,
        trigger,
        force,
        context,
        captureGeneration,
        captureSession,
        requiresFreshPaint,
      );
    }

    return _executePhysicalCapture(
      trigger: trigger,
      force: force,
      freshness: freshness,
      context: context,
      queueWaitMicros: queueWaitMicros,
      captureGeneration: captureGeneration,
      captureSession: captureSession,
      session: session,
      capturer: capturer,
      hasCompatibleFrame: hasCompatibleFrame,
      requiresFreshPaint: requiresFreshPaint,
      captureCancellation: captureCancellation,
    );
  }

  bool _captureExecutionIsSuppressed(bool bypassExplorationSuppression) =>
      _disposed ||
      _capturePaused ||
      _skipCapture ||
      _captureInFlight ||
      _explorationCaptureIsSuppressed(bypassExplorationSuppression);

  bool _explorationCaptureIsSuppressed(bool bypass) =>
      _shouldSuppressFrameCapture && !bypass;

  bool _isEligibleForBudgetSkip(
    _CaptureFreshness freshness,
    TugboatFrameTrigger trigger,
  ) =>
      freshness == _CaptureFreshness.reusable &&
      _isBudgetSkippableTrigger(trigger) &&
      config.screenshotBudget.skipEligibleWhenDegraded &&
      _screenshotBudget.shouldSkipEligible;

  bool _isBudgetSkippableTrigger(TugboatFrameTrigger trigger) =>
      trigger != TugboatFrameTrigger.initial &&
      trigger != TugboatFrameTrigger.lifecycle;

  Future<_CaptureExecution> _executePhysicalCapture({
    required TugboatFrameTrigger trigger,
    required bool force,
    required _CaptureFreshness freshness,
    required _CaptureRequestContext context,
    required int queueWaitMicros,
    required int captureGeneration,
    required TugboatSession? captureSession,
    required TugboatSession session,
    required ScreenshotCapturer capturer,
    required bool hasCompatibleFrame,
    required bool requiresFreshPaint,
    required Future<void> captureCancellation,
  }) async {
    _beginCapture();
    try {
      final resolved = await _resolvePhysicalCaptureAttempt(
        capturer: capturer,
        context: context,
        captureGeneration: captureGeneration,
        captureSession: captureSession,
        session: session,
        hasCompatibleFrame: hasCompatibleFrame,
        force: force,
        requiresFreshPaint: requiresFreshPaint,
        captureCancellation: captureCancellation,
        queueWaitMicros: queueWaitMicros,
        trigger: trigger,
      );
      final execution = resolved.execution;
      if (execution != null) {
        return execution;
      }
      final attempt = resolved.attempt!;
      final result = resolved.result!;
      _recordPhysicalCaptureBudget(queueWaitMicros, attempt, result);
      final reused = _reusePhysicalCaptureResult(
        capturer: capturer,
        context: context,
        result: result,
        force: force,
        requiresFreshPaint: requiresFreshPaint,
      );
      if (reused != null) return reused;
      return _publishPhysicalCaptureResult(
        trigger: trigger,
        session: session,
        context: context,
        attempt: attempt,
        result: result,
        capturer: capturer,
      );
    } finally {
      _endCapture();
      if (_scheduledCapture != null) {
        _ensureCapturePumpScheduled();
      }
    }
  }

  Future<_PhysicalCaptureAttemptResolution> _resolvePhysicalCaptureAttempt({
    required ScreenshotCapturer capturer,
    required _CaptureRequestContext context,
    required int captureGeneration,
    required TugboatSession? captureSession,
    required TugboatSession session,
    required bool hasCompatibleFrame,
    required bool force,
    required bool requiresFreshPaint,
    required Future<void> captureCancellation,
    required int queueWaitMicros,
    required TugboatFrameTrigger trigger,
  }) async {
    var allowPaintSkip =
        trigger != TugboatFrameTrigger.initial && hasCompatibleFrame;
    var captureForce = force || requiresFreshPaint || !hasCompatibleFrame;
    for (var retry = 0; retry < 2; retry++) {
      final attempt = await _capturePhysicalAttempt(
        capturer,
        context,
        captureGeneration,
        captureSession,
        captureForce,
        requiresFreshPaint,
        allowPaintSkip,
        captureCancellation,
      );
      final failed = _failedPhysicalCaptureExecution(
        attempt,
        context,
        captureGeneration,
        captureSession,
        session,
        queueWaitMicros,
      );
      if (failed != null) {
        return _PhysicalCaptureAttemptResolution.execution(failed);
      }
      _lastCaptureFailure = null;
      final result = attempt.result!;
      if (!result.skippedByPaintGeneration) {
        return _PhysicalCaptureAttemptResolution.captured(attempt, result);
      }
      final reuse = _reuseWithoutCapture(
        context: context,
        outcome: _CaptureOutcome.paintGenerationUnchanged,
        reuseReason: 'paint_generation',
      );
      if (reuse.outcome != _CaptureOutcome.noCompatibleFrame || retry == 1) {
        return _PhysicalCaptureAttemptResolution.execution(reuse);
      }
      allowPaintSkip = false;
      captureForce = true;
    }
    return const _PhysicalCaptureAttemptResolution.execution(
      _CaptureExecution(outcome: _CaptureOutcome.captureProcessingFailed),
    );
  }

  Future<ScreenshotCaptureAttempt> _capturePhysicalAttempt(
    ScreenshotCapturer capturer,
    _CaptureRequestContext context,
    int generation,
    TugboatSession? session,
    bool force,
    bool requiresFreshPaint,
    bool allowPaintSkip,
    Future<void> cancelled,
  ) => capturer.captureAttempt(
    force: force,
    waitForFrame: true,
    requireFreshPaint: requiresFreshPaint,
    allowPaintGenerationSkip: allowPaintSkip,
    degraded: _screenshotBudget.shouldSkipEligible,
    cancelled: cancelled,
    isCurrent: () => _isPhysicalAttemptCurrent(context, generation, session),
  );

  bool _isPhysicalAttemptCurrent(
    _CaptureRequestContext context,
    int generation,
    TugboatSession? session,
  ) =>
      _captureContextStillCurrent(context, generation, session) &&
      !_capturePaused &&
      !_skipCapture;

  _CaptureExecution? _failedPhysicalCaptureExecution(
    ScreenshotCaptureAttempt attempt,
    _CaptureRequestContext context,
    int generation,
    TugboatSession? captureSession,
    TugboatSession session,
    int queueWaitMicros,
  ) {
    if (_physicalAttemptIsUsable(attempt, context, generation, session)) {
      return null;
    }
    _lastCaptureFailure = attempt.failure;
    _recordFailedPhysicalCaptureBudget(
      attempt,
      context,
      generation,
      captureSession,
      queueWaitMicros,
    );
    return _CaptureExecution(
      outcome: _physicalFailureOutcome(
        attempt,
        context,
        generation,
        captureSession,
      ),
      failure: attempt.failure,
      cancellationReason: _physicalFailureCancellationReason(attempt),
      backendTrace: attempt.result?.backendTrace,
    );
  }

  bool _physicalAttemptIsUsable(
    ScreenshotCaptureAttempt attempt,
    _CaptureRequestContext context,
    int generation,
    TugboatSession session,
  ) =>
      attempt.result != null &&
      !_disposed &&
      _captureContextStillCurrent(context, generation, session);

  void _recordFailedPhysicalCaptureBudget(
    ScreenshotCaptureAttempt attempt,
    _CaptureRequestContext context,
    int generation,
    TugboatSession? session,
    int queueWaitMicros,
  ) {
    if (attempt.failure == ScreenshotCaptureFailure.cancelled ||
        !_captureContextStillCurrent(context, generation, session)) {
      return;
    }
    _screenshotBudget.record(
      queueWaitMicros: queueWaitMicros,
      frameWaitMicros: attempt.frameWaitMicros,
      readbackMicros: 0,
      encodeMicros: 0,
      encodedBytes: 0,
      dropReason: attempt.failure?.name ?? 'capture_failed',
    );
  }

  _CaptureOutcome _physicalFailureOutcome(
    ScreenshotCaptureAttempt attempt,
    _CaptureRequestContext context,
    int generation,
    TugboatSession? session,
  ) => _captureContextStillCurrent(context, generation, session)
      ? _diagnosticOutcomeForFailure(attempt.failure)
      : _CaptureOutcome.supersededRoute;

  String? _physicalFailureCancellationReason(
    ScreenshotCaptureAttempt attempt,
  ) => attempt.failure == ScreenshotCaptureFailure.cancelled
      ? 'superseded_route'
      : null;

  void _recordPhysicalCaptureBudget(
    int queueWaitMicros,
    ScreenshotCaptureAttempt attempt,
    ScreenshotCaptureResult result,
  ) {
    _screenshotBudget.record(
      queueWaitMicros: queueWaitMicros,
      frameWaitMicros: attempt.frameWaitMicros,
      readbackMicros: result.captureMicros,
      maskMicros: result.maskMicros,
      encodeMicros: result.encodeMicros,
      encodedBytes: result.bytes.length,
      coalescedCapture: result.skippedByDHash,
    );
  }

  _CaptureExecution? _reusePhysicalCaptureResult({
    required ScreenshotCapturer capturer,
    required _CaptureRequestContext context,
    required ScreenshotCaptureResult result,
    required bool force,
    required bool requiresFreshPaint,
  }) {
    if (result.skippedByDHash) {
      return _reuseDHashCaptureResult(capturer, context, result);
    }
    final existingId = _hashToFrameId[result.contentHash];
    if (!_canReuseContentHash(existingId, context, force, requiresFreshPaint)) {
      return null;
    }
    _reuseCompatibleFrame(existingId!, context, 'content_hash');
    capturer.commitAcceptedPaintGeneration(result.paintGeneration);
    capturer.commitAcceptedDHash(result.dHash);
    _maybeEmitSceneInventory();
    return _CaptureExecution(
      outcome: _CaptureOutcome.exactContentReused,
      frameId: existingId,
      reuseReason: 'content_hash',
      backendTrace: result.backendTrace,
    );
  }

  _CaptureExecution _reuseDHashCaptureResult(
    ScreenshotCapturer capturer,
    _CaptureRequestContext context,
    ScreenshotCaptureResult result,
  ) {
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
      backendTrace: result.backendTrace,
    );
  }

  bool _canReuseContentHash(
    String? frameId,
    _CaptureRequestContext context,
    bool force,
    bool requiresFreshPaint,
  ) =>
      !force &&
      !requiresFreshPaint &&
      frameId != null &&
      _isFrameCompatible(frameId, context);

  _CaptureExecution _publishPhysicalCaptureResult({
    required TugboatFrameTrigger trigger,
    required TugboatSession session,
    required _CaptureRequestContext context,
    required ScreenshotCaptureAttempt attempt,
    required ScreenshotCaptureResult result,
    required ScreenshotCapturer capturer,
  }) {
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
      captureSessionId: session.id,
      requestedBackend: result.backendTrace.requested,
      resolvedBackend: result.backendTrace.resolved,
      fallbackReason: result.backendTrace.fallbackReason,
    );
    session.frames.add(frame);
    session.frameBytes[frameId] = result.bytes;
    _hashToFrameId[result.contentHash] = frameId;
    _latestFrameId = frameId;
    final boundary = _observeBoundaryTransform(result.boundaryLogicalRect);
    _frameProvenance[frameId] = _FrameProvenance(
      context: context.withBoundaryTransform(
        logicalRect: result.boundaryLogicalRect,
        generation: boundary.generation,
      ),
      completedAtMs: atMs,
      sequence: ++_frameCompletionSequence,
    );
    capturer.commitAcceptedPaintGeneration(result.paintGeneration);
    capturer.commitAcceptedDHash(result.dHash);
    _maybeEmitSceneInventory();
    _sinkHub?.recordFrame(
      frame,
      result.bytes,
      sessionId: session.id,
      actionId: _activeActionId,
    );
    _trim();
    if (!_disposed) notifyListeners();
    return _CaptureExecution(
      outcome: _CaptureOutcome.freshAccepted,
      frameId: frameId,
      backendTrace: result.backendTrace,
    );
  }

  Future<_CaptureExecution> _executeCaptureOverride(
    Future<String?> Function({
      required TugboatFrameTrigger trigger,
      required bool force,
    })
    override,
    TugboatFrameTrigger trigger,
    bool force,
    _CaptureRequestContext context,
    int generation,
    TugboatSession? session,
    bool requiresFreshPaint,
  ) async {
    _beginCapture();
    try {
      final frameId = await override(trigger: trigger, force: force);
      if (!_captureContextStillCurrent(context, generation, session)) {
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
      return _overrideExecutionForFrame(context, resolved);
    } finally {
      _endCapture();
      if (_scheduledCapture != null) _ensureCapturePumpScheduled();
    }
  }

  _CaptureExecution _overrideExecutionForFrame(
    _CaptureRequestContext context,
    String? frameId,
  ) => _CaptureExecution(
    outcome: frameId == null
        ? (_unavailableAttachmentReason(context) == 'no_frame_available'
              ? _CaptureOutcome.noFrameAvailable
              : _CaptureOutcome.noCompatibleFrame)
        : _CaptureOutcome.freshAccepted,
    frameId: frameId,
  );

  _CaptureExecution? _takeDebugCaptureExecution() {
    final debugOutcome = debugNextCaptureOutcome;
    if (debugOutcome == null) return null;
    debugNextCaptureOutcome = null;
    final frameId = debugNextCaptureFrameId;
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
      frameId: frameId,
      cancellationReason: outcome == _CaptureOutcome.cancelled ? 'debug' : null,
      reuseReason: _debugCaptureReuseReason(outcome),
    );
  }

  String? _debugCaptureReuseReason(_CaptureOutcome outcome) =>
      switch (outcome) {
        _CaptureOutcome.exactContentReused => 'content_hash',
        _CaptureOutcome.perceptualHashCoalesced => 'dhash',
        _CaptureOutcome.paintGenerationUnchanged => 'paint_generation',
        _ => null,
      };

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
      locale: _currentLocale,
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
      if (!_canResolveExplorationTap(resolver, rootRender)) {
        failureReason = TugboatTargetResolutionFailureReason.resolutionError;
      } else {
        final activeResolver = resolver!;
        final captureRoot = rootRender as RenderBox;
        final localPoint = captureRoot.globalToLocal(tx.origin.startPosition);
        final boundary = Offset.zero & captureRoot.size;
        if (!boundary.contains(localPoint)) {
          failureReason =
              TugboatTargetResolutionFailureReason.outsideCaptureBoundary;
        } else {
          // Exploration accepts one synchronous rebuild for the primary
          // pointer so delayed same-route state cannot reuse an old token map.
          activeResolver.invalidateTokenMapCache();
          final tapContext = activeResolver.buildTapContext(
            tapPosition: tx.origin.startPosition,
            route: tx.origin.route,
            keyboardOpen: _isKeyboardOpen(),
            modalOpen: _isModalOpen(),
            detectDismissibleBarrier: true,
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
            final capturedSemanticSnapshot = _viewportSemantics
                .captureTapSnapshot(
                  position: tx.origin.startPosition,
                  resolver: resolver,
                  boundaryKey: _boundaryKey,
                  inventory: inventory,
                );
            semanticSnapshot = capturedSemanticSnapshot;
            target = _selectExplorationTapTarget(
              rawTarget: rawTarget,
              inventory: inventory,
              semanticResolution: capturedSemanticSnapshot.resolution,
              allowDismissibleBarrierTarget:
                  tapContext.tapHitsDismissibleBarrier &&
                  !_isOpaquePlatformTarget(rawTarget),
            );
            if (target == null) {
              failureReason = _targetFailureReason(
                rawTarget: rawTarget,
                semanticResolution: capturedSemanticSnapshot.resolution,
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
      semanticEncodedPayload: semanticSnapshot?.encodedPayload,
      semanticBuildMicros: semanticSnapshot?.buildMicros ?? 0,
      visualObservationGeneration: _visualObservationGeneration,
      frameCompletionSequence: _frameCompletionSequence,
      buildMicros: stopwatch.elapsedMicroseconds,
      failureReason: failureReason,
    );
    tx.preTapEvidence = evidence;
    _recordExplorationPreTapDiagnostic(tx, evidence);
  }

  bool _canResolveExplorationTap(
    AnchorResolver? resolver,
    RenderObject? rootRender,
  ) => resolver != null && rootRender is RenderBox && rootRender.hasSize;

  TugboatTargetAnchor? _selectExplorationTapTarget({
    required TugboatTargetAnchor? rawTarget,
    required TugboatSceneInventory inventory,
    required TugboatViewportSemanticResolution? semanticResolution,
    required bool allowDismissibleBarrierTarget,
  }) {
    if (_isOpaquePlatformTarget(rawTarget)) return null;
    final semanticTarget = _semanticExplorationTapTarget(
      rawTarget,
      inventory,
      semanticResolution,
    );
    if (semanticTarget != null) return semanticTarget;

    final rawFingerprint = rawTarget?.fingerprint;
    if (rawFingerprint == null || rawFingerprint.isEmpty) return null;
    final entry = _inventoryEntryForFingerprint(inventory, rawFingerprint);
    if (entry == null ||
        (!_isTapInventoryEntry(entry) && !allowDismissibleBarrierTarget)) {
      return null;
    }
    return rawTarget;
  }

  TugboatTargetAnchor? _semanticExplorationTapTarget(
    TugboatTargetAnchor? rawTarget,
    TugboatSceneInventory inventory,
    TugboatViewportSemanticResolution? resolution,
  ) {
    final fingerprint = resolution?.linkedFingerprint;
    if (fingerprint?.isEmpty != false) return null;
    final entry = _inventoryEntryForFingerprint(inventory, fingerprint!);
    if (entry == null || !_isTapInventoryEntry(entry)) return null;
    if (resolution?.status == 'matched_inventory_fallback') {
      return _targetAnchorFromInventory(
        entry,
        base: rawTarget,
        confidence: 'low',
      );
    }
    if (resolution?.status != 'matched_actionable') return null;
    return rawTarget?.fingerprint == entry.fingerprint
        ? rawTarget
        : _targetAnchorFromInventory(entry, base: rawTarget);
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
    final isOpaqueSurface =
        widgetType.contains('AndroidView') ||
        widgetType.contains('UiKitView') ||
        widgetType.contains('PlatformView') ||
        widgetType.contains('Texture');
    if (!isOpaqueSurface) return false;
    final hasActionableFlutterWrapper =
        target!.actions.isNotEmpty &&
        target.fingerprint?.isNotEmpty == true &&
        target.canonicalPath?.isNotEmpty == true;
    return !hasActionableFlutterWrapper;
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
      _resolveExplorationTapEvidence(tx, position);
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
        detectDismissibleBarrier: false,
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

  void _resolveExplorationTapEvidence(
    InteractionTransaction tx,
    Offset position,
  ) {
    final evidence = tx.preTapEvidence;
    if (evidence == null) {
      tx.targetResolutionFailureReason =
          TugboatTargetResolutionFailureReason.noTargetAtPoint;
      return;
    }
    if (!_explorationEvidenceMatchesOrigin(evidence, tx)) {
      tx.targetResolutionFailureReason =
          TugboatTargetResolutionFailureReason.staleRouteGeneration;
      return;
    }
    tx.targetAnchor = evidence.targetAnchor;
    tx.targetResolutionFailureReason = evidence.failureReason;
    _publishExplorationTapEvidence(evidence);
    _logExplorationTapResolution(position, evidence.semanticResolution);
  }

  bool _explorationEvidenceMatchesOrigin(
    TugboatPreTapEvidence evidence,
    InteractionTransaction tx,
  ) =>
      evidence.routeEpoch == tx.origin.routeEpoch &&
      evidence.routeInstanceId == tx.origin.routeInstanceId &&
      evidence.route == tx.origin.route;

  void _publishExplorationTapEvidence(TugboatPreTapEvidence evidence) {
    final inventory = evidence.inventory;
    if (inventory != null) {
      _emitSceneInventory(inventory, emitViewportSemanticMap: false);
    }
    final semanticMap = evidence.semanticMap;
    if (semanticMap == null) return;
    _viewportSemantics.publishTapSnapshot(
      TugboatViewportTapSnapshot(
        map: semanticMap,
        encodedPayload: evidence.semanticEncodedPayload,
        resolution: evidence.semanticResolution,
        buildMicros: evidence.semanticBuildMicros,
      ),
    );
  }

  void _logExplorationTapResolution(
    Offset position,
    TugboatViewportSemanticResolution? resolution,
  ) {
    if (resolution != null && _viewportSemanticMapDebugLogsEnabled) {
      tugboatLogViewportSemanticTapResolution(position, resolution);
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

    if (_completePanOrZoomPointerUp(pending, position)) return;
    if (_completeSkippedTapPointerUp(pending, position)) return;

    _resolveTapEvidence(pending, pending.origin.startPosition);
    // Keep the single-use claim alive through the pointer-up turn so sync
    // onTap → Navigator can attribute without letting later redirects borrow.
    _releaseInteractionClaim(pending);

    final work = _TapSettleWork(session: _session);
    _activeTapSettles.add(work);
    unawaited(_resolveTapSettle(work, pending, position, _activeRouteCapture));
  }

  bool _completePanOrZoomPointerUp(
    InteractionTransaction pending,
    Offset position,
  ) {
    if (!pending.isPanOrZoom || !_panOrZoomCanComplete(pending)) return false;
    _completePointerGesture(pending, position);
    return true;
  }

  bool _panOrZoomCanComplete(InteractionTransaction pending) =>
      pending.gesture == InteractionGesture.zoomIn ||
      pending.gesture == InteractionGesture.zoomOut ||
      pending.scrollStartEventIds.isEmpty;

  bool _completeSkippedTapPointerUp(
    InteractionTransaction pending,
    Offset position,
  ) {
    if (!pending.skipsTapSettlement) return false;
    final scrollId = pending.scrollStartEventIds.isEmpty
        ? null
        : pending.scrollStartEventIds.first;
    pending.gesture = scrollId == null
        ? InteractionGesture.swipe
        : InteractionGesture.scroll;
    pending.endPosition = position;
    _clearCausalRouteState(pending.id);
    if (scrollId == null) {
      _publishCompletedGestureAfterCapture(pending);
    } else {
      _scrollInteractions[scrollId] = pending;
      _publishResolvedScrollInteraction(scrollId);
    }
    if (!_disposed) notifyListeners();
    return true;
  }

  void _completePointerGesture(
    InteractionTransaction pending,
    Offset position,
  ) {
    pending.endPosition = position;
    _clearCausalRouteState(pending.id);
    _publishCompletedGestureAfterCapture(pending);
    if (!_disposed) notifyListeners();
  }

  Future<void> _resolveTapSettle(
    _TapSettleWork work,
    InteractionTransaction pending,
    Offset position,
    _RouteCaptureWork? routeCaptureAtPointerUp,
  ) async {
    try {
      final initialRouteCapture = _initialTapRouteCapture(
        routeCaptureAtPointerUp,
        pending,
      );
      await _waitForTapSettleWindow(work, pending, initialRouteCapture);
      if (!_isActiveTapSettle(work)) return;
      // A tap may only inherit a route barrier that was causally claimed by
      // that exact tap. In particular, an automatic navigation that starts
      // while this tap is waiting to settle is independent evidence: joining
      // it would incorrectly copy its destination frame and route event ID
      // onto the tap.
      final routeCapture = await _tapRouteCaptureAfterSettle(
        work,
        pending,
        initialRouteCapture,
      );
      if (!_isActiveTapSettle(work)) return;
      _TapSettleObservation observation;
      if (routeCapture != null) {
        final routeObservation = await _tapObservationForRouteCapture(
          work,
          pending,
          routeCapture,
        );
        if (routeObservation == null) return;
        observation = routeObservation;
      } else {
        final standaloneObservation = await _tapObservationForStandaloneCapture(
          work,
          pending,
        );
        if (standaloneObservation == null) return;
        observation = standaloneObservation;
      }
      await _publishTapSettleObservation(work, pending, observation);
    } finally {
      _activeTapSettles.remove(work);
      _clearCausalRouteState(pending.id);
      work.complete();
    }
  }

  _RouteCaptureWork? _initialTapRouteCapture(
    _RouteCaptureWork? routeCapture,
    InteractionTransaction pending,
  ) => routeCapture?.change.causeEventId == pending.id ? routeCapture : null;

  Future<void> _waitForTapSettleWindow(
    _TapSettleWork work,
    InteractionTransaction pending,
    _RouteCaptureWork? initialRouteCapture,
  ) async {
    if (initialRouteCapture == null && config.settleDelay > Duration.zero) {
      final deadline = _scheduleDelay(config.settleDelay);
      work.attachDeadlineCancellation(deadline.cancel);
      await deadline.done;
    }
    if (_isActiveTapSettle(work)) {
      await _waitForTapClaimWindow(work, pending);
    }
  }

  Future<void> _waitForTapClaimWindow(
    _TapSettleWork work,
    InteractionTransaction pending,
  ) async {
    final deadlineMs = pending.reconciliationDeadlineMs;
    if (!_hasTapClaimWindow(pending, deadlineMs)) return;
    final remainingMs = deadlineMs! - atMs;
    if (remainingMs <= 0) return;
    final deadline = _scheduleDelay(Duration(milliseconds: remainingMs));
    work.attachDeadlineCancellation(deadline.cancel);
    await pending.awaitSuccessorOrDeadline(deadline.done);
    deadline.cancel();
  }

  bool _hasTapClaimWindow(InteractionTransaction pending, int? deadlineMs) =>
      config.interactionClaimWindow > Duration.zero &&
      !pending.claimed &&
      deadlineMs != null;

  Future<_RouteCaptureWork?> _tapRouteCaptureAfterSettle(
    _TapSettleWork work,
    InteractionTransaction pending,
    _RouteCaptureWork? initialRouteCapture,
  ) async {
    final routeCapture = initialRouteCapture ?? _causalRouteCaptureFor(pending);
    if (routeCapture != null || config.settleDelay > Duration.zero) {
      return routeCapture;
    }
    await Future<void>.microtask(() {});
    if (!_isActiveTapSettle(work)) return null;
    return _causalRouteCaptureFor(pending);
  }

  _RouteCaptureWork? _causalRouteCaptureFor(InteractionTransaction pending) {
    final active = _activeRouteCapture;
    if (active?.change.causeEventId == pending.id) return active;
    return _causalRouteCaptures[pending.id];
  }

  Future<_TapSettleObservation?> _tapObservationForRouteCapture(
    _TapSettleWork work,
    InteractionTransaction pending,
    _RouteCaptureWork routeCapture,
  ) async {
    _causalRouteCaptures.remove(pending.id);
    final barrier = await _awaitRouteCaptureBarrier(
      routeCapture,
      expectedCauseEventId: pending.id,
    );
    if (!_isActiveTapSettle(work)) return null;
    if (!_routeBarrierWasSupersededByAutomatic(barrier, pending)) {
      return _tapObservationFromRouteBarrier(pending, barrier);
    }
    return _supersededRouteTapObservation(work, pending, barrier);
  }

  bool _routeBarrierWasSupersededByAutomatic(
    ({_RouteCaptureWork work, _RouteCaptureResult result}) barrier,
    InteractionTransaction pending,
  ) =>
      barrier.result.outcome == _RouteCaptureOutcome.cancelled &&
      barrier.work.change.causeEventId == pending.id &&
      barrier.work.supersededBy?.change.causeEventId != pending.id;

  Future<_TapSettleObservation?> _supersededRouteTapObservation(
    _TapSettleWork work,
    InteractionTransaction pending,
    ({_RouteCaptureWork work, _RouteCaptureResult result}) barrier,
  ) async {
    final successor = barrier.work.supersededBy;
    final temporalBarrier = successor == null
        ? null
        : await _awaitRouteCaptureBarrier(successor);
    if (!_isActiveTapSettle(work)) return null;
    final afterFrame = temporalBarrier == null
        ? null
        : _temporalAfterFrame(pending, temporalBarrier.result.frameId);
    return _TapSettleObservation(
      routeEpoch: _routeEpoch,
      route: _currentRoute,
      afterFrame: afterFrame,
      navigationOutcome: 'navigation_unavailable',
      captureOutcome: 'superseded_route_epoch',
      captureFailure: 'superseded_route_epoch',
      captureRequestId: afterFrame == null
          ? null
          : temporalBarrier!.result.captureRequestId,
    );
  }

  Future<_TapSettleObservation?> _tapObservationForStandaloneCapture(
    _TapSettleWork work,
    InteractionTransaction pending,
  ) async {
    final requestedRouteEpoch = _routeEpoch;
    final requestedRoute = _currentRoute;
    final routeChanged = _tapRouteChangedFromOrigin(
      pending,
      requestedRouteEpoch,
      requestedRoute,
    );
    final capture = _requestCaptureCancellable(
      trigger: TugboatFrameTrigger.interaction,
      force: true,
      settleDelay: Duration.zero,
      relatedEventId: pending.id,
    );
    work.attachCaptureCancellation((reason) => capture.cancel(reason));
    final resolution = await capture.resolution;
    if (!_isActiveTapSettle(work)) return null;
    if (_standaloneCaptureHasReplacementRoute(
      pending,
      resolution,
      requestedRouteEpoch,
    )) {
      return _standaloneTapSuccessorObservation(
        work,
        pending,
        resolution,
        _activeRouteCapture!,
      );
    }
    return _standaloneTapSameRouteObservation(
      pending,
      resolution,
      requestedRouteEpoch,
      requestedRoute,
      routeChanged,
    );
  }

  bool _tapRouteChangedFromOrigin(
    InteractionTransaction pending,
    int requestedEpoch,
    String? requestedRoute,
  ) =>
      requestedEpoch != pending.origin.routeEpoch ||
      requestedRoute != pending.origin.route ||
      _causalRouteSupersededInteractions.contains(pending.id);

  bool _standaloneCaptureHasReplacementRoute(
    InteractionTransaction pending,
    _CaptureResolution resolution,
    int requestedRouteEpoch,
  ) {
    final frameMatches = _frameMatchesTapOrigin(pending, resolution.frameId);
    final replacement = _activeRouteCapture;
    return !frameMatches &&
        replacement != null &&
        replacement.epoch != requestedRouteEpoch;
  }

  bool _frameMatchesTapOrigin(InteractionTransaction pending, String? frameId) {
    final provenance = frameId == null ? null : _frameProvenance[frameId];
    return provenance != null &&
        provenance.context.routeEpoch == pending.origin.routeEpoch &&
        provenance.context.route == pending.origin.route;
  }

  Future<_TapSettleObservation?> _standaloneTapSuccessorObservation(
    _TapSettleWork work,
    InteractionTransaction pending,
    _CaptureResolution resolution,
    _RouteCaptureWork replacementRoute,
  ) async {
    final causal = replacementRoute.change.causeEventId == pending.id;
    final barrier = await _awaitRouteCaptureBarrier(
      replacementRoute,
      expectedCauseEventId: causal ? pending.id : null,
    );
    if (!_isActiveTapSettle(work)) return null;
    final successor = _tapObservationFromRouteBarrier(
      pending,
      barrier,
      navigationOutcome: causal ? 'navigated' : 'visual_successor',
    );
    return _successorTapObservation(pending, resolution, successor, causal);
  }

  _TapSettleObservation _successorTapObservation(
    InteractionTransaction pending,
    _CaptureResolution resolution,
    _TapSettleObservation successor,
    bool causal,
  ) => _TapSettleObservation(
    routeEpoch: successor.routeEpoch,
    route: successor.route,
    afterFrame: _temporalAfterFrame(pending, successor.afterFrame),
    navigationOutcome: successor.navigationOutcome,
    captureOutcome: causal
        ? resolution.outcome.wireName
        : 'superseded_route_epoch',
    captureFailure: causal
        ? resolution.outcome.wireName
        : 'superseded_route_epoch',
    routeEventId: causal ? successor.routeEventId : null,
    captureRequestId: resolution.requestId,
  );

  _TapSettleObservation _standaloneTapSameRouteObservation(
    InteractionTransaction pending,
    _CaptureResolution resolution,
    int requestedRouteEpoch,
    String? requestedRoute,
    bool routeChanged,
  ) {
    final matchesOrigin = _frameMatchesTapOrigin(pending, resolution.frameId);
    final superseded =
        routeChanged || _captureWasSuperseded(resolution, matchesOrigin);
    final captured = matchesOrigin && !routeChanged;
    return _TapSettleObservation(
      routeEpoch: requestedRouteEpoch,
      route: requestedRoute,
      afterFrame: captured
          ? resolution.frameId
          : _temporalAfterFrame(pending, _latestFrameId),
      navigationOutcome: 'same_route',
      captureOutcome: captured
          ? 'captured'
          : (superseded ? 'superseded_route_epoch' : 'failed'),
      captureFailure: captured
          ? null
          : (superseded
                ? 'superseded_route_epoch'
                : resolution.outcome.wireName),
      captureRequestId: resolution.requestId,
    );
  }

  bool _captureWasSuperseded(
    _CaptureResolution resolution,
    bool matchesOrigin,
  ) => !matchesOrigin && resolution.outcome == _CaptureOutcome.supersededRoute;

  Future<void> _publishTapSettleObservation(
    _TapSettleWork work,
    InteractionTransaction pending,
    _TapSettleObservation observation,
  ) async {
    Future<void> write() =>
        _writeTapSettleObservation(work, pending, observation);
    if (observation.isDegraded) {
      try {
        await write();
      } catch (error, stackTrace) {
        debugPrint('[tugboat] interaction settle failed: $error\n$stackTrace');
      }
      return;
    }
    await _enqueue('interaction_settle', write);
  }

  Future<void> _writeTapSettleObservation(
    _TapSettleWork work,
    InteractionTransaction pending,
    _TapSettleObservation observation,
  ) async {
    if (!_isActiveTapSettle(work)) return;
    pending.gesture = InteractionGesture.tap;
    pending.afterFrame = observation.afterFrame;
    _publishCanonicalInteraction(pending);
    if (!_disposed) notifyListeners();
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
    final validFrame = _isValidRouteBarrierFrame(
      frameId,
      provenance,
      settledRoute,
    );
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

  bool _isValidRouteBarrierFrame(
    String? frameId,
    _FrameProvenance? provenance,
    _RouteCaptureWork route,
  ) =>
      frameId != null &&
      provenance != null &&
      provenance.context.captureSessionId == _session?.id &&
      provenance.context.routeEpoch == route.epoch &&
      provenance.context.route == route.change.destinationRoute;

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
        locale: tx.origin.locale,
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
    final normalized = _normalizedScrollOffsets(metrics, tracker, endOffset);
    return TugboatViewportSemanticScrollContext(
      trigger: trigger,
      scrollableFingerprint: tracker.targetAnchor?.fingerprint,
      axis: metrics.axis.name,
      offset: metrics.pixels,
      offsetNorm: normalized.offset,
      startOffset: tracker.startOffset,
      endOffset: endOffset,
      depth: tracker.depth,
      observedTopNorm: normalized.top,
      observedBottomNorm: normalized.bottom,
    );
  }

  ({double? offset, double? top, double? bottom}) _normalizedScrollOffsets(
    ScrollMetrics metrics,
    _ScrollTracker tracker,
    double? endOffset,
  ) {
    final extent = metrics.maxScrollExtent;
    if (extent <= 0) return (offset: null, top: null, bottom: null);
    final offset = metrics.pixels / extent;
    final start = tracker.startOffset / extent;
    final end = (endOffset ?? metrics.pixels) / extent;
    return (
      offset: offset,
      top: start < end ? start : end,
      bottom: start > end ? start : end,
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
    final sampleDue = _recordScrollSampleIfDue(session, tracker, metrics, now);
    final screenshotDue = _captureScrollScreenshotIfDue(tracker, now);
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

  bool _recordScrollSampleIfDue(
    TugboatSession session,
    _ScrollTracker tracker,
    ScrollMetrics metrics,
    DateTime now,
  ) {
    if (!_scrollSampleIsDue(tracker, now)) return false;
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
    return true;
  }

  bool _scrollSampleIsDue(_ScrollTracker tracker, DateTime now) =>
      config.captureScrollSamples &&
      _scrollIntervalHasElapsed(tracker.lastSampleAt, now);

  bool _captureScrollScreenshotIfDue(_ScrollTracker tracker, DateTime now) {
    if (!config.captureScrollScreenshots ||
        !_scrollIntervalHasElapsed(tracker.lastScreenshotAt, now)) {
      return false;
    }
    tracker.lastScreenshotAt = now;
    unawaited(
      _requestCaptureCancellable(
        trigger: TugboatFrameTrigger.scroll,
        dropWhenBusy: true,
      ).done,
    );
    return true;
  }

  bool _scrollIntervalHasElapsed(DateTime? last, DateTime now) =>
      last == null || now.difference(last) >= config.scrollCaptureInterval;

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
    unawaited(
      _completePointerLinkedScrollEnd(
        tracker,
        completion,
        idleDeadline.done,
        captureSession,
        captureLifecycleEpoch,
        metrics,
      ),
    );
  }

  Future<void> _completePointerLinkedScrollEnd(
    _ScrollTracker tracker,
    _PendingScrollCompletion completion,
    Future<void> deadline,
    TugboatSession? session,
    int lifecycleEpoch,
    ScrollMetrics metrics,
  ) async {
    await deadline;
    final wasPending =
        _pendingScrollEndDelayCancellations.remove(tracker.startEventId) !=
        null;
    if (!wasPending ||
        completion.resolved ||
        !_isCaptureLifecycleCurrent(session, lifecycleEpoch)) {
      return;
    }
    if (tracker.routeEpoch != _routeEpoch) {
      await _completeSupersededScrollEnd(
        tracker,
        completion,
        session,
        lifecycleEpoch,
      );
      return;
    }
    await _completeCurrentScrollEnd(
      tracker,
      completion,
      session,
      lifecycleEpoch,
      metrics,
    );
  }

  Future<void> _completeSupersededScrollEnd(
    _ScrollTracker tracker,
    _PendingScrollCompletion completion,
    TugboatSession? session,
    int lifecycleEpoch,
  ) async {
    // Make the interaction capture attempt. A later route frame can be a
    // temporal observation, but it does not make the route scroll-caused.
    final afterCapture = _requestCaptureCancellable(
      trigger: TugboatFrameTrigger.interaction,
      force: true,
      settleDelay: Duration.zero,
      relatedEventId: tracker.startEventId,
    );
    final afterResolution = await afterCapture.resolution;
    if (!_isCaptureLifecycleCurrent(session, lifecycleEpoch)) return;
    completion
      ..captureResolution = afterResolution
      ..captureOutcome = 'superseded_route_epoch'
      ..resolved = true;
    _publishResolvedScrollInteraction(tracker.startEventId);
    if (!_disposed) notifyListeners();
  }

  Future<void> _completeCurrentScrollEnd(
    _ScrollTracker tracker,
    _PendingScrollCompletion completion,
    TugboatSession? session,
    int lifecycleEpoch,
    ScrollMetrics metrics,
  ) async {
    final afterCapture = _requestCaptureCancellable(
      trigger: TugboatFrameTrigger.interaction,
      force: true,
      settleDelay: Duration.zero,
      relatedEventId: tracker.startEventId,
    );
    final afterResolution = await afterCapture.resolution;
    if (!_isCaptureLifecycleCurrent(session, lifecycleEpoch)) {
      return;
    }
    final afterFrame = afterResolution.outcome == _CaptureOutcome.freshAccepted
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
    if (_routeCaptureIsUnavailable) {
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

    _applyVisibleRouteChange(change);

    final captureKey = _routeCaptureKey(change.navigatorId);
    final prior = _activeRouteCaptures[captureKey];
    _replacePriorRouteCapture(captureKey, prior);
    final work = _RouteCaptureWork(
      epoch: ++_routeEpoch,
      change: change,
      deadline: _routeCaptureDeadline(transition, change),
    );
    _activeRouteCaptures[captureKey] = work;
    _latestRouteCaptureKey = captureKey;
    prior?.supersededBy = work;
    _updateRouteCaptureCausality(prior, change, work);
    _skipCapture = transition.transitionDuration > Duration.zero;
    _startRouteBarrierTimeout(work);
    // Wake a reconciliation-pending settle only after this capture is visible
    // in `_activeRouteCaptures`, otherwise settle can miss the causal barrier.
    _signalRouteCause(change);
    _scheduleRouteCaptureFinalization(work);
    return work.done.then<void>((_) {});
  }

  bool get _routeCaptureIsUnavailable =>
      _disposed || _session == null || _endSessionFuture != null;

  void _applyVisibleRouteChange(_VisibleRouteChange change) {
    if (!change.updatesRoute) return;
    _currentRoute = change.destinationRoute;
    _currentRouteIdentity = TugboatRouteIdentity(
      route: change.destinationRoute,
      routeName: change.routeName,
      routeType: change.routeType,
      routeNamed: change.routeNamed,
    );
    _currentNavigatorId = change.navigatorId;
    _currentRouteInstanceId = change.routeInstanceId;
  }

  void _replacePriorRouteCapture(String key, _RouteCaptureWork? prior) {
    if (prior != null) {
      _activeRouteCaptures.remove(key);
      if (_latestRouteCaptureKey == key) {
        _latestRouteCaptureKey = _activeRouteCaptures.keys.isEmpty
            ? null
            : _activeRouteCaptures.keys.last;
      }
      prior.cancel('superseded_route');
      _cancelScheduledCaptureWaiters('superseded_route');
      _advanceCaptureGeneration();
      return;
    }
    if (_activeRouteCaptures.isEmpty) _advanceCaptureGeneration();
  }

  Duration _routeCaptureDeadline(
    _RouteTransition transition,
    _VisibleRouteChange change,
  ) =>
      transition.transitionDuration +
      (_shouldSuppressFrameCapture && !change.bypassesExplorationSuppression
          ? Duration.zero
          : config.settleDelay);

  void _updateRouteCaptureCausality(
    _RouteCaptureWork? prior,
    _VisibleRouteChange change,
    _RouteCaptureWork work,
  ) {
    final previousCause = prior?.change.causeEventId;
    if (previousCause != null && previousCause != change.causeEventId) {
      _causalRouteCaptures.remove(previousCause);
      _causalRouteSupersededInteractions.add(previousCause);
    }
    final cause = change.causeEventId;
    if (cause != null) _causalRouteCaptures[cause] = work;
  }

  void _signalRouteCause(_VisibleRouteChange change) {
    final cause = change.causeEventId;
    if (cause != null) _interactions.byId(cause)?.signalSuccessorClaimed();
  }

  void _scheduleRouteCaptureFinalization(_RouteCaptureWork work) {
    if (work.deadline <= Duration.zero) {
      unawaited(_enqueue('route_change', () => _finalizeRouteCapture(work)));
    } else {
      _startRouteDeadline(work);
    }
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
      _applyVisibleRouteChange(change);
      final capture = _requestCaptureCancellable(
        trigger: TugboatFrameTrigger.route,
        force: true,
        bypassExplorationSuppression: change.bypassesExplorationSuppression,
        // The route deadline already includes the configured post-route
        // settle. Scheduling it again here would delay capture twice and can
        // strand widget-backed callers waiting for route completion.
        settleDelay: Duration.zero,
      );
      work.attachCaptureCancellation((reason) => capture.cancel(reason));
      final captureResult = await _awaitRouteReadback(work, capture.resolution);
      captureRequestId = captureResult.captureRequestId;
      final failure = _finalizeFailedRouteResult(
        work,
        change,
        captureResult,
        captureRequestId,
      );
      if (failure.stop) {
        outcome = _RouteCaptureOutcome.failed;
        captureFailure = failure.captureFailure;
        routeEventId = failure.routeEventId;
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
      routeEventId = _emitCompletedRouteCapture(
        change,
        captureResult,
        captureRequestId,
        afterFrame,
        outcome,
      );
      _maybeEmitSceneInventory();
      if (!_disposed) notifyListeners();
    } finally {
      _completeFinalizedRouteCapture(
        work,
        outcome,
        afterFrame,
        routeEventId,
        captureFailure,
        captureRequestId,
      );
    }
  }

  ({bool stop, String? captureFailure, String? routeEventId})
  _finalizeFailedRouteResult(
    _RouteCaptureWork work,
    _VisibleRouteChange change,
    _RouteCaptureResult result,
    String? requestId,
  ) {
    if (result.outcome != _RouteCaptureOutcome.failed) {
      return (stop: false, captureFailure: null, routeEventId: null);
    }
    if (!_isActiveRouteCapture(work)) {
      return (stop: true, captureFailure: null, routeEventId: null);
    }
    final eventId = _emitFailedRouteCapture(change, result, requestId);
    if (!_disposed) notifyListeners();
    return (
      stop: true,
      captureFailure: _lastCaptureFailure?.name,
      routeEventId: eventId,
    );
  }

  void _completeFinalizedRouteCapture(
    _RouteCaptureWork work,
    _RouteCaptureOutcome outcome,
    String? afterFrame,
    String? eventId,
    String? failure,
    String? requestId,
  ) {
    _removeFinalizedRouteCapture(work);
    work.complete(
      _RouteCaptureResult(
        outcome,
        frameId: afterFrame,
        routeEventId: eventId,
        captureFailure: failure,
        captureRequestId: requestId,
      ),
    );
  }

  void _removeFinalizedRouteCapture(_RouteCaptureWork work) {
    final key = _routeCaptureKey(work.change.navigatorId);
    if (!identical(_activeRouteCaptures[key], work)) return;
    _activeRouteCaptures.remove(key);
    if (_latestRouteCaptureKey == key) {
      _latestRouteCaptureKey = _activeRouteCaptures.keys.isEmpty
          ? null
          : _activeRouteCaptures.keys.last;
    }
    _skipCapture = false;
  }

  String _emitFailedRouteCapture(
    _VisibleRouteChange change,
    _RouteCaptureResult result,
    String? requestId,
  ) {
    final eventId = _nextId('event');
    _attachCauseInteractionEvidence(change.causeEventId);
    _emitRouteChange(
      routeEventId: eventId,
      change: change,
      result: TugboatInteractionResult.navigated,
      extraData: _failedRouteCaptureData(result.captureFailure, requestId),
    );
    return eventId;
  }

  Map<String, Object?> _failedRouteCaptureData(
    String? failure,
    String? requestId,
  ) => {
    'captureOutcome': 'failed',
    if (failure != null) 'captureFailure': failure,
    if (requestId != null) 'captureRequestId': requestId,
  };

  String _emitCompletedRouteCapture(
    _VisibleRouteChange change,
    _RouteCaptureResult result,
    String? requestId,
    String? afterFrame,
    _RouteCaptureOutcome outcome,
  ) {
    final eventId = _nextId('event');
    _attachCauseInteractionEvidence(
      change.causeEventId,
      afterFrame: afterFrame,
    );
    _emitRouteChange(
      routeEventId: eventId,
      change: change,
      afterFrame: afterFrame,
      result: TugboatInteractionResult.navigated,
      extraData: outcome == _RouteCaptureOutcome.failed
          ? _failedRouteCaptureData(result.captureFailure, requestId)
          : _routeRequestIdData(requestId),
    );
    return eventId;
  }

  Map<String, Object?> _routeRequestIdData(String? requestId) =>
      requestId == null ? const {} : {'captureRequestId': requestId};

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
    final identity = tugboatRouteIdentityFor(route);
    return _RouteTransition(
      kind: _RouteNavigationKind.parse(type),
      routeName: identity.route,
      identity: identity,
      transitionDuration: route is TransitionRoute<dynamic>
          ? route.transitionDuration
          : Duration.zero,
      overlayKind: tugboatOverlayKindFor(route),
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
  _VisibleRouteChange? _resolveVisibleRouteChange(
    _RouteTransition transition, {
    Route<dynamic>? destinationRoute,
    Route<dynamic>? departingRoute,
    NavigatorState? navigatorState,
  }) {
    if (_isInvisibleRouteRemoval(transition, transition.routeName)) {
      return null;
    }
    final surface = _resolveRouteSurface(
      transition,
      destinationRoute,
      departingRoute,
      navigatorState,
    );
    _rememberObservedRoute(transition, destinationRoute, surface);
    _visualObservationGeneration++;
    return _visibleRouteChangeFor(
      transition,
      surface,
      claimed: _tryClaimInteractionCause(
        navigatorId: surface.navigatorId ?? _currentNavigatorId,
      ),
    );
  }

  void _rememberObservedRoute(
    _RouteTransition transition,
    Route<dynamic>? destinationRoute,
    ({
      String? navigatorId,
      String? parentNavigatorId,
      String? routeInstanceId,
      String? fromRouteInstanceId,
      int stackRevision,
    })
    surface,
  ) {
    final instanceId = surface.routeInstanceId;
    final navigatorId = surface.navigatorId;
    if (destinationRoute == null || instanceId == null || navigatorId == null) {
      return;
    }
    _surfaces.remember(
      instanceId: instanceId,
      navigatorId: navigatorId,
      identity: transition.identity,
      overlayKind: transition.overlayKind,
    );
  }

  _VisibleRouteChange _visibleRouteChangeFor(
    _RouteTransition transition,
    ({
      String? navigatorId,
      String? parentNavigatorId,
      String? routeInstanceId,
      String? fromRouteInstanceId,
      int stackRevision,
    })
    surface, {
    required InteractionTransaction? claimed,
  }) {
    final updatesRoute = _updatesVisibleRoute(transition);
    final identity = transition.identity;
    final from = _currentRouteIdentity;
    final cause = _routeCauseFromClaim(claimed);
    final presentation = _presentationFor(transition, surface);
    final navigatorId = surface.navigatorId ?? _currentNavigatorId;
    return _VisibleRouteChange(
      previousRoute: _currentRoute,
      destinationRoute: updatesRoute ? identity.route : _currentRoute,
      navigation: transition.kind.wireName,
      updatesRoute: updatesRoute,
      routeName: identity.routeName,
      routeType: identity.routeType,
      routeNamed: identity.routeNamed,
      fromRouteName: from?.routeName,
      fromRouteType: from?.routeType,
      fromRouteNamed: from?.routeNamed,
      navigatorId: navigatorId,
      parentNavigatorId: surface.parentNavigatorId,
      routeInstanceId: surface.routeInstanceId ?? _currentRouteInstanceId,
      fromRouteInstanceId: surface.fromRouteInstanceId,
      stackRevision: surface.stackRevision,
      overlayKind: transition.overlayKind,
      visualObservationGeneration: _visualObservationGeneration,
      navigationOrigin: claimed == null
          ? 'automatic_or_unknown'
          : 'interaction',
      causeEventId: cause.id,
      causeTargetFingerprint: cause.fingerprint,
      causeGesture: cause.gesture,
      interactionAttribution: claimed?.attribution,
      presentedOverRoute: presentation?.presentedOverRoute,
      presentedOverRouteInstanceId: presentation?.presentedOverRouteInstanceId,
      presentedOverOverlayKind: presentation?.presentedOverOverlayKind,
      hostPageRoute: presentation?.hostPageRoute,
      hostPageRouteInstanceId: presentation?.hostPageRouteInstanceId,
      routeStack: _routeStackSnapshot(navigatorId),
      routeStackTruncated: _routeStackTruncated(navigatorId),
    );
  }

  List<Map<String, Object?>> _routeStackSnapshot(String? navigatorId) =>
      navigatorId == null
      ? const <Map<String, Object?>>[]
      : _surfaces.stackSnapshot(navigatorId);

  bool _routeStackTruncated(String? navigatorId) =>
      navigatorId != null && _surfaces.stackTruncated(navigatorId);

  bool _updatesVisibleRoute(_RouteTransition transition) =>
      transition.kind == _RouteNavigationKind.push ||
      transition.kind == _RouteNavigationKind.replace ||
      transition.routeName != null;

  ({String? id, String? fingerprint, String? gesture}) _routeCauseFromClaim(
    InteractionTransaction? claimed,
  ) {
    if (claimed == null) {
      return (id: null, fingerprint: null, gesture: null);
    }
    final fingerprint =
        claimed.origin.targetAnchor?.fingerprint ??
        claimed.targetAnchor?.fingerprint;
    return (
      id: claimed.id,
      fingerprint: fingerprint == null || fingerprint.isEmpty
          ? null
          : fingerprint,
      gesture: claimed.gesture.wireName,
    );
  }

  _RoutePresentationParent? _presentationFor(
    _RouteTransition transition,
    ({
      String? navigatorId,
      String? parentNavigatorId,
      String? routeInstanceId,
      String? fromRouteInstanceId,
      int stackRevision,
    })
    surface,
  ) {
    final navigatorId = surface.navigatorId;
    final instanceId = surface.routeInstanceId;
    if (navigatorId == null || instanceId == null) return null;
    return _surfaces.presentationParent(
      navigatorId: navigatorId,
      instanceId: instanceId,
      overlayKind: transition.overlayKind,
      isPush: transition.kind == _RouteNavigationKind.push,
    );
  }

  bool _isInvisibleRouteRemoval(
    _RouteTransition transition,
    String? routeName,
  ) =>
      transition.kind == _RouteNavigationKind.remove &&
      (routeName == null || routeName == _currentRoute);

  ({
    String? navigatorId,
    String? parentNavigatorId,
    String? routeInstanceId,
    String? fromRouteInstanceId,
    int stackRevision,
  })
  _resolveRouteSurface(
    _RouteTransition transition,
    Route<dynamic>? destinationRoute,
    Route<dynamic>? departingRoute,
    NavigatorState? navigatorState,
  ) {
    if (navigatorState == null) {
      return _resolveUnboundRouteSurface(destinationRoute);
    }
    final navigatorId = _surfaces.idForNavigator(navigatorState);
    final parentNavigatorId = _surfaces.parentOf(navigatorId);
    return _resolveBoundRouteSurface(
      transition,
      navigatorId,
      parentNavigatorId,
      destinationRoute,
      departingRoute,
    );
  }

  ({
    String? navigatorId,
    String? parentNavigatorId,
    String? routeInstanceId,
    String? fromRouteInstanceId,
    int stackRevision,
  })
  _resolveUnboundRouteSurface(Route<dynamic>? destinationRoute) {
    if (destinationRoute == null) {
      return (
        navigatorId: null,
        parentNavigatorId: null,
        routeInstanceId: null,
        fromRouteInstanceId: null,
        stackRevision: 0,
      );
    }
    return (
      navigatorId: null,
      parentNavigatorId: null,
      routeInstanceId: _surfaces.idForRoute(destinationRoute),
      fromRouteInstanceId: _currentRouteInstanceId,
      stackRevision: _currentRouteInstanceId == null ? 1 : 2,
    );
  }

  ({
    String? navigatorId,
    String? parentNavigatorId,
    String? routeInstanceId,
    String? fromRouteInstanceId,
    int stackRevision,
  })
  _resolveBoundRouteSurface(
    _RouteTransition transition,
    String navigatorId,
    String? parentNavigatorId,
    Route<dynamic>? destinationRoute,
    Route<dynamic>? departingRoute,
  ) => switch (transition.kind) {
    _RouteNavigationKind.push => _pushRouteSurface(
      navigatorId,
      parentNavigatorId,
      destinationRoute,
    ),
    _RouteNavigationKind.replace => _replaceRouteSurface(
      navigatorId,
      parentNavigatorId,
      destinationRoute,
      departingRoute,
    ),
    _RouteNavigationKind.pop || _RouteNavigationKind.remove => _popRouteSurface(
      navigatorId,
      parentNavigatorId,
      destinationRoute,
      departingRoute,
    ),
  };

  ({
    String? navigatorId,
    String? parentNavigatorId,
    String? routeInstanceId,
    String? fromRouteInstanceId,
    int stackRevision,
  })
  _pushRouteSurface(
    String navigatorId,
    String? parentNavigatorId,
    Route<dynamic>? route,
  ) {
    final id = route == null ? null : _surfaces.idForRoute(route);
    return (
      navigatorId: navigatorId,
      parentNavigatorId: parentNavigatorId,
      routeInstanceId: id,
      fromRouteInstanceId: _currentRouteInstanceId,
      stackRevision: id == null ? 0 : _surfaces.push(navigatorId, id),
    );
  }

  ({
    String? navigatorId,
    String? parentNavigatorId,
    String? routeInstanceId,
    String? fromRouteInstanceId,
    int stackRevision,
  })
  _replaceRouteSurface(
    String navigatorId,
    String? parentNavigatorId,
    Route<dynamic>? route,
    Route<dynamic>? departing,
  ) {
    final id = route == null ? null : _surfaces.idForRoute(route);
    final from = _surfaces.peekRouteId(departing) ?? _currentRouteInstanceId;
    return (
      navigatorId: navigatorId,
      parentNavigatorId: parentNavigatorId,
      routeInstanceId: id,
      fromRouteInstanceId: from,
      stackRevision: id == null ? 0 : _surfaces.replaceTop(navigatorId, id),
    );
  }

  ({
    String? navigatorId,
    String? parentNavigatorId,
    String? routeInstanceId,
    String? fromRouteInstanceId,
    int stackRevision,
  })
  _popRouteSurface(
    String navigatorId,
    String? parentNavigatorId,
    Route<dynamic>? route,
    Route<dynamic>? departing,
  ) {
    final from = _surfaces.peekRouteId(departing) ?? _currentRouteInstanceId;
    final revision = _surfaces.pop(navigatorId, departingInstanceId: from);
    final id = route == null
        ? _surfaces.top(navigatorId)
        : _surfaces.idForRoute(route);
    return (
      navigatorId: navigatorId,
      parentNavigatorId: parentNavigatorId,
      routeInstanceId: id,
      fromRouteInstanceId: from,
      stackRevision: revision,
    );
  }

  /// Observer-time single-use claim. Returns the transaction only when exactly
  /// one unambiguous active pointer is eligible for this navigator/session.
  ///
  /// The route writer retains the claim until terminal publication, so a
  /// causeEventId remains stable across route and gesture settlement.
  InteractionTransaction? _tryClaimInteractionCause({String? navigatorId}) {
    if (!_claimingIsAvailable) return null;
    final eligible = _interactions.eligibleForClaim(
      nowMs: atMs,
      sessionId: _session?.id,
    );
    if (eligible.length != 1) return _rejectAmbiguousClaim(eligible);
    final tx = eligible.single;
    if (_navigatorDoesNotMatchClaim(tx, navigatorId)) return null;
    tx.claimed = true;
    final windowActive = config.interactionClaimWindow > Duration.zero;
    final isPending = _interactions.pendingAt(tx.pointerId) != null;
    tx.attribution = (isPending || !windowActive)
        ? InteractionAttribution.direct
        : InteractionAttribution.delayedLikely;
    return tx;
  }

  bool get _claimingIsAvailable =>
      _captureLifecycleActive && _endSessionFuture == null;

  InteractionTransaction? _rejectAmbiguousClaim(
    List<InteractionTransaction> eligible,
  ) {
    if (eligible.length > 1) {
      for (final tx in eligible) {
        tx.rejectionReason ??= InteractionRejectionReason.competingPointer;
      }
    }
    return null;
  }

  bool _navigatorDoesNotMatchClaim(
    InteractionTransaction tx,
    String? navigatorId,
  ) {
    final mismatch =
        navigatorId != null &&
        tx.origin.navigatorId != null &&
        tx.origin.navigatorId != navigatorId;
    if (mismatch) {
      tx.rejectionReason ??= InteractionRejectionReason.navigatorMismatch;
    }
    return mismatch;
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
    final localeEvent = event.locale == null && _currentLocale != null
        ? event.copyWith(locale: _currentLocale)
        : event;
    final enriched = attachActionContext
        ? localeEvent.withExplorationContext(
            captureSessionId: session.id,
            activationRequestId: _firstDefined([
              session.activationRequestId,
              activationRequestId,
            ]),
            explorationRunId: _firstDefined([
              localeEvent.explorationRunId,
              _activeExplorationRunId,
              config.explorationRunId,
            ]),
            actionId: _firstDefined([localeEvent.actionId, _activeActionId]),
          )
        : localeEvent.copyWith(
            captureSessionId: _firstDefined([
              localeEvent.captureSessionId,
              session.id,
            ]),
            activationRequestId: _firstDefined([
              localeEvent.activationRequestId,
              session.activationRequestId,
              activationRequestId,
            ]),
            explorationRunId: _firstDefined([
              localeEvent.explorationRunId,
              session.explorationRunId,
            ]),
          );
    session.events.add(enriched);
    _sinkHub?.recordEvent(enriched);
    _trim();
  }

  String? _firstDefined(List<String?> values) {
    for (final value in values) {
      if (value != null) return value;
    }
    return null;
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
