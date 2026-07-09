import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'collector_config.dart';

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
    this.sessionId,
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
  final String? sessionId;
  final TugboatStateAnchor? stateAnchor;
  final TugboatTargetAnchor? targetAnchor;
  final String? beforeFrame;
  final String? afterFrame;
  final TugboatInteractionResult? result;
  final String? relatedEventId;
  final Map<String, Object?> data;
  final String? explorationRunId;
  final String? actionId;

  Map<String, Object?> toJson() => {
    'id': id,
    'atMs': atMs,
    'type': type,
    if (sessionId != null) 'sessionId': sessionId,
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

  TugboatEvent withExplorationContext({
    String? sessionId,
    String? explorationRunId,
    String? actionId,
  }) => TugboatEvent(
    id: id,
    atMs: atMs,
    type: type,
    sessionId: sessionId ?? this.sessionId,
    stateAnchor: stateAnchor,
    targetAnchor: targetAnchor,
    beforeFrame: beforeFrame,
    afterFrame: afterFrame,
    result: result,
    relatedEventId: relatedEventId,
    data: data,
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
  });

  final String id;
  final DateTime startedAt;
  final String platform;
  final TugboatRect viewport;
  final TugboatCollectorAppInfo? appInfo;

  final List<TugboatFrame> frames = [];
  final Map<String, Uint8List> frameBytes = {};
  final List<TugboatEvent> events = [];
  final List<TugboatScrollSample> scrollSamples = [];
  bool truncated = false;

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
    'schemaVersion': 6,
    'session': {
      'id': id,
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
