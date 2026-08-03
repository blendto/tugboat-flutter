import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'collector_config.dart';

/// Current session JSON schema. Writers emit this; readers accept 6–9.
///
/// Schema 9 stops emitting value and semantic-annotation event data.
const int tugboatSessionSchemaVersion = 9;

/// Event selection channel for enrichment / insight / replay consumers.
enum TugboatEventStream {
  /// Default enrichment stream — prefer `type: interaction`.
  semantic,

  /// Route/state/scroll/pointer observations linked to interactions.
  evidence,

  /// Capture health and support diagnostics.
  diagnostic,

  /// Temporary dual-write of legacy `tap` / `tap_settled` / `swipe` peers.
  legacyProjection;

  String get wireName => switch (this) {
    TugboatEventStream.semantic => 'semantic',
    TugboatEventStream.evidence => 'evidence',
    TugboatEventStream.diagnostic => 'diagnostic',
    TugboatEventStream.legacyProjection => 'legacy_projection',
  };

  static TugboatEventStream parse(String? raw) {
    switch (raw) {
      case 'evidence':
        return TugboatEventStream.evidence;
      case 'diagnostic':
        return TugboatEventStream.diagnostic;
      case 'legacy_projection':
        return TugboatEventStream.legacyProjection;
      case 'semantic':
      case null:
      default:
        return TugboatEventStream.semantic;
    }
  }
}

/// How finalized gestures are published to sinks.
enum TugboatInteractionPublishMode {
  /// Only legacy `tap` / `tap_settled` / `swipe` on the semantic stream.
  legacyOnly,

  /// Canonical `interaction` plus legacy peers on [TugboatEventStream.legacyProjection].
  dualWrite,

  /// Canonical `interaction` only.
  canonicalOnly,
}

/// Wire-compatible string aliases for tests and docs.
const String tugboatEventStreamSemantic = 'semantic';
const String tugboatEventStreamEvidence = 'evidence';
const String tugboatEventStreamDiagnostic = 'diagnostic';
const String tugboatEventStreamLegacyProjection = 'legacy_projection';

const int tugboatInteractionSchemaVersion = 1;

/// Whether [event] is a default enrichment / insight candidate.
bool tugboatEventIsEnrichmentCandidate(TugboatEvent event) {
  switch (event.stream) {
    case TugboatEventStream.diagnostic:
    case TugboatEventStream.evidence:
    case TugboatEventStream.legacyProjection:
      return false;
    case TugboatEventStream.semantic:
      if (event.type == 'interaction') return true;
      return event.type == 'tap' ||
          event.type == 'tap_settled' ||
          event.type == 'swipe';
  }
}

class TugboatRect {
  const TugboatRect(this.x, this.y, this.width, this.height);

  factory TugboatRect.fromRect(Rect rect) =>
      TugboatRect(rect.left, rect.top, rect.width, rect.height);

  final double x;
  final double y;
  final double width;
  final double height;

  Rect get rect => Rect.fromLTWH(x, y, width, height);

  Map<String, Object> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
}

enum TugboatFrameTrigger { initial, tap, scroll, route, lifecycle, manual }

enum TugboatInteractionResult { changed, noVisibleChange, navigated, unknown }

class TugboatFrame {
  const TugboatFrame({
    required this.id,
    required this.atMs,
    required this.width,
    required this.height,
    required this.contentHash,
    this.masked = false,
    this.trigger = TugboatFrameTrigger.manual,
    this.byteLength = 0,
    this.captureMicros = 0,
    this.captureSessionId,
  });

  final String id;
  final int atMs;
  final int width;
  final int height;
  final String contentHash;
  final bool masked;
  final TugboatFrameTrigger trigger;
  final int byteLength;
  final int captureMicros;
  final String? captureSessionId;

  Map<String, Object?> toJson() => {
    'id': id,
    'atMs': atMs,
    'width': width,
    'height': height,
    'contentHash': contentHash,
    'masked': masked,
    'trigger': trigger.name,
    'byteLength': byteLength,
    'captureMicros': captureMicros,
    if (captureSessionId != null) 'captureSessionId': captureSessionId,
  };
}

class TugboatScrollSample {
  const TugboatScrollSample({
    required this.atMs,
    required this.offset,
    this.beforeFrame,
    this.afterFrame,
    this.scrollableFingerprint,
    this.axis,
    this.offsetNorm,
  });

  final int atMs;
  final double offset;
  final String? beforeFrame;
  final String? afterFrame;
  final String? scrollableFingerprint;
  final String? axis;
  final double? offsetNorm;

  Map<String, Object?> toJson() => {
    'atMs': atMs,
    'offset': offset,
    if (beforeFrame != null) 'beforeFrame': beforeFrame,
    if (afterFrame != null) 'afterFrame': afterFrame,
    if (scrollableFingerprint != null)
      'scrollableFingerprint': scrollableFingerprint,
    if (axis != null) 'axis': axis,
    if (offsetNorm != null) 'offsetNorm': offsetNorm,
  };
}

class TugboatEvent {
  const TugboatEvent({
    required this.id,
    required this.atMs,
    required this.type,
    this.stream = TugboatEventStream.semantic,
    this.sessionId,
    this.captureSessionId,
    this.activationRequestId,
    this.stateAnchor,
    this.targetAnchor,
    this.beforeFrame,
    this.afterFrame,
    this.result,
    this.relatedEventId,
    this.data = const {},
    this.explorationRunId,
    this.actionId,
  });

  final String id;
  final int atMs;
  final String type;
  final TugboatEventStream stream;

  /// Legacy alias for [captureSessionId].
  final String? sessionId;
  final String? captureSessionId;
  final String? activationRequestId;
  final TugboatStateAnchor? stateAnchor;
  final TugboatTargetAnchor? targetAnchor;
  final String? beforeFrame;
  final String? afterFrame;
  final TugboatInteractionResult? result;
  final String? relatedEventId;
  final Map<String, Object?> data;
  final String? explorationRunId;
  final String? actionId;

  String? get effectiveCaptureSessionId => captureSessionId ?? sessionId;

  bool get isSemanticStream => stream == TugboatEventStream.semantic;

  bool get isEnrichmentCandidate => tugboatEventIsEnrichmentCandidate(this);

  Map<String, Object?> toJson() => {
    'id': id,
    'atMs': atMs,
    'type': type,
    'stream': stream.wireName,
    if (sessionId != null) 'sessionId': sessionId,
    if (captureSessionId != null) 'captureSessionId': captureSessionId,
    if (activationRequestId != null) 'activationRequestId': activationRequestId,
    if (stateAnchor != null) 'stateAnchor': stateAnchor!.toJson(),
    if (targetAnchor != null) 'targetAnchor': targetAnchor!.toJson(),
    if (beforeFrame != null) 'beforeFrame': beforeFrame,
    if (afterFrame != null) 'afterFrame': afterFrame,
    if (result != null) 'result': result!.name,
    if (relatedEventId != null) 'relatedEventId': relatedEventId,
    if (data.isNotEmpty) 'data': data,
    if (explorationRunId != null) 'explorationRunId': explorationRunId,
    if (actionId != null) 'actionId': actionId,
  };

  TugboatEvent copyWith({
    String? id,
    int? atMs,
    String? type,
    TugboatEventStream? stream,
    String? sessionId,
    String? captureSessionId,
    String? activationRequestId,
    TugboatStateAnchor? stateAnchor,
    TugboatTargetAnchor? targetAnchor,
    String? beforeFrame,
    String? afterFrame,
    TugboatInteractionResult? result,
    String? relatedEventId,
    Map<String, Object?>? data,
    String? explorationRunId,
    String? actionId,
  }) => TugboatEvent(
    id: id ?? this.id,
    atMs: atMs ?? this.atMs,
    type: type ?? this.type,
    stream: stream ?? this.stream,
    sessionId: sessionId ?? this.sessionId,
    captureSessionId: captureSessionId ?? this.captureSessionId,
    activationRequestId: activationRequestId ?? this.activationRequestId,
    stateAnchor: stateAnchor ?? this.stateAnchor,
    targetAnchor: targetAnchor ?? this.targetAnchor,
    beforeFrame: beforeFrame ?? this.beforeFrame,
    afterFrame: afterFrame ?? this.afterFrame,
    result: result ?? this.result,
    relatedEventId: relatedEventId ?? this.relatedEventId,
    data: data ?? this.data,
    explorationRunId: explorationRunId ?? this.explorationRunId,
    actionId: actionId ?? this.actionId,
  );

  TugboatEvent withData(Map<String, Object?> updates) =>
      copyWith(data: {...data, ...updates});

  TugboatEvent withExplorationContext({
    String? sessionId,
    String? captureSessionId,
    String? activationRequestId,
    String? explorationRunId,
    String? actionId,
  }) => copyWith(
    sessionId: sessionId ?? this.sessionId,
    captureSessionId: captureSessionId ?? this.captureSessionId,
    activationRequestId: activationRequestId ?? this.activationRequestId,
    explorationRunId: explorationRunId ?? this.explorationRunId,
    actionId: actionId ?? this.actionId,
  );
}

class TugboatSession {
  TugboatSession({
    required this.id,
    required this.startedAt,
    required this.platform,
    required this.viewport,
    this.appInfo,
    this.activationRequestId,
    this.explorationRunId,
    this.collectorSessionId,
  });

  /// SDK-generated capture session ID (emitted evidence identity).
  final String id;
  final DateTime startedAt;
  final String platform;
  final TugboatRect viewport;
  final TugboatCollectorAppInfo? appInfo;

  /// Host-supplied activation / request correlation ID.
  final String? activationRequestId;

  /// Exploration control-plane run ID from config, if any.
  final String? explorationRunId;

  /// Collector-issued transport ID (stamped after session_start accept).
  String? collectorSessionId;

  final List<TugboatFrame> frames = [];
  final Map<String, Uint8List> frameBytes = {};
  final List<TugboatEvent> events = [];
  final List<TugboatScrollSample> scrollSamples = [];
  bool truncated = false;

  String get captureSessionId => id;

  Size get viewportSize {
    if (viewport.width > 0 && viewport.height > 0) {
      return Size(viewport.width, viewport.height);
    }
    return const Size(390, 844);
  }

  TugboatFrame? frameById(String? id) {
    if (id == null) return null;
    for (final frame in frames) {
      if (frame.id == id) return frame;
    }
    return null;
  }

  TugboatFrame? latestSettledFrame() => frames.isEmpty ? null : frames.last;

  TugboatFrame? frameAtMs(int atMs) {
    TugboatFrame? latest;
    for (final frame in frames) {
      if (frame.atMs > atMs) break;
      latest = frame;
    }
    return latest;
  }

  int get totalFrameBytes =>
      frameBytes.values.fold<int>(0, (sum, bytes) => sum + bytes.length);

  double get averageFrameBytes =>
      frames.isEmpty ? 0 : totalFrameBytes / frames.length;

  Map<String, Object?> toJson() => {
    'schemaVersion': tugboatSessionSchemaVersion,
    'session': {
      'id': id,
      'captureSessionId': id,
      if (activationRequestId != null)
        'activationRequestId': activationRequestId,
      if (collectorSessionId != null) 'collectorSessionId': collectorSessionId,
      if (explorationRunId != null) 'explorationRunId': explorationRunId,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'platform': platform,
      'viewport': viewport.toJson(),
      'truncated': truncated,
      if (appInfo != null) 'appInfo': appInfo!.toJson(),
    },
    'frames': frames.map((frame) => frame.toJson()).toList(),
    'events': events.map((event) => event.toJson()).toList(),
    if (scrollSamples.isNotEmpty)
      'scrollSamples': scrollSamples.map((s) => s.toJson()).toList(),
  };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}
