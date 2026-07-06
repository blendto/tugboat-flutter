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

  factory TugboatFrame.fromJson(Map<String, dynamic> json) => TugboatFrame(
    id: json['id'] as String,
    atMs: json['atMs'] as int,
    width: json['width'] as int,
    height: json['height'] as int,
    contentHash: json['contentHash'] as String,
    masked: json['masked'] as bool? ?? false,
    trigger: TugboatFrameTrigger.values.byName(
      json['trigger'] as String? ?? 'manual',
    ),
    byteLength: json['byteLength'] as int? ?? 0,
    captureMicros: json['captureMicros'] as int? ?? 0,
  );
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

  factory TugboatScrollSample.fromJson(Map<String, dynamic> json) =>
      TugboatScrollSample(
        atMs: json['atMs'] as int,
        offset: (json['offset'] as num).toDouble(),
        beforeFrame: json['beforeFrame'] as String?,
        afterFrame: json['afterFrame'] as String?,
        scrollableFingerprint: json['scrollableFingerprint'] as String?,
        axis: json['axis'] as String?,
        offsetNorm: (json['offsetNorm'] as num?)?.toDouble(),
      );
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

  factory TugboatEvent.fromJson(Map<String, dynamic> json) => TugboatEvent(
    id: json['id'] as String,
    atMs: json['atMs'] as int,
    type: json['type'] as String,
    sessionId: json['sessionId'] as String?,
    stateAnchor: json['stateAnchor'] == null
        ? null
        : TugboatStateAnchor.fromJson(
            Map<String, dynamic>.from(json['stateAnchor'] as Map),
          ),
    targetAnchor: json['targetAnchor'] == null
        ? null
        : TugboatTargetAnchor.fromJson(
            Map<String, dynamic>.from(json['targetAnchor'] as Map),
          ),
    beforeFrame: json['beforeFrame'] as String?,
    afterFrame: json['afterFrame'] as String?,
    result: json['result'] == null
        ? null
        : TugboatInteractionResult.values.byName(json['result'] as String),
    relatedEventId: json['relatedEventId'] as String?,
    data: Map<String, Object?>.from(json['data'] as Map? ?? {}),
    explorationRunId: json['explorationRunId'] as String?,
    actionId: json['actionId'] as String?,
  );

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

  static TugboatSession fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 6) {
      throw const FormatException('Unsupported Tugboat session schema version.');
    }
    final sessionJson = Map<String, dynamic>.from(json['session'] as Map);
    final viewportJson = Map<String, dynamic>.from(
      sessionJson['viewport'] as Map,
    );
    final appInfoJson = sessionJson['appInfo'];
    final session = TugboatSession(
      id: sessionJson['id'] as String,
      startedAt: DateTime.parse(sessionJson['startedAt'] as String),
      platform: sessionJson['platform'] as String,
      viewport: TugboatRect(
        (viewportJson['x'] as num).toDouble(),
        (viewportJson['y'] as num).toDouble(),
        (viewportJson['width'] as num).toDouble(),
        (viewportJson['height'] as num).toDouble(),
      ),
      appInfo: appInfoJson == null
          ? null
          : TugboatCollectorAppInfo(
              name: (appInfoJson as Map)['name'] as String,
              version: appInfoJson['version'] as String,
              buildNumber: appInfoJson['buildNumber'] as String,
              installationId: appInfoJson['installationId'] as String,
            ),
    )..truncated = sessionJson['truncated'] as bool? ?? false;

    session.frames.addAll(
      (json['frames'] as List<dynamic>? ?? []).map(
        (frame) => TugboatFrame.fromJson(Map<String, dynamic>.from(frame as Map)),
      ),
    );
    session.events.addAll(
      (json['events'] as List<dynamic>? ?? []).map(
        (event) => TugboatEvent.fromJson(Map<String, dynamic>.from(event as Map)),
      ),
    );
    session.scrollSamples.addAll(
      (json['scrollSamples'] as List<dynamic>? ?? []).map(
        (sample) => TugboatScrollSample.fromJson(
          Map<String, dynamic>.from(sample as Map),
        ),
      ),
    );
    return session;
  }
}
