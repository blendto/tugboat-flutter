import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'anchors.dart';

class PmkitRect {
  const PmkitRect(this.x, this.y, this.width, this.height);

  factory PmkitRect.fromRect(Rect rect) =>
      PmkitRect(rect.left, rect.top, rect.width, rect.height);

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

enum PmkitFrameTrigger { initial, tap, scroll, route, lifecycle, manual }

enum PmkitInteractionResult { changed, noVisibleChange, navigated, unknown }

class PmkitFrame {
  const PmkitFrame({
    required this.id,
    required this.atMs,
    required this.width,
    required this.height,
    required this.contentHash,
    this.masked = false,
    this.trigger = PmkitFrameTrigger.manual,
    this.byteLength = 0,
    this.captureMicros = 0,
  });

  final String id;
  final int atMs;
  final int width;
  final int height;
  final String contentHash;
  final bool masked;
  final PmkitFrameTrigger trigger;
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

  factory PmkitFrame.fromJson(Map<String, dynamic> json) => PmkitFrame(
    id: json['id'] as String,
    atMs: json['atMs'] as int,
    width: json['width'] as int,
    height: json['height'] as int,
    contentHash: json['contentHash'] as String,
    masked: json['masked'] as bool? ?? false,
    trigger: PmkitFrameTrigger.values.byName(
      json['trigger'] as String? ?? 'manual',
    ),
    byteLength: json['byteLength'] as int? ?? 0,
    captureMicros: json['captureMicros'] as int? ?? 0,
  );
}

class PmkitScrollSample {
  const PmkitScrollSample({
    required this.atMs,
    required this.offset,
    this.beforeFrame,
    this.afterFrame,
  });

  final int atMs;
  final double offset;
  final String? beforeFrame;
  final String? afterFrame;

  Map<String, Object?> toJson() => {
    'atMs': atMs,
    'offset': offset,
    if (beforeFrame != null) 'beforeFrame': beforeFrame,
    if (afterFrame != null) 'afterFrame': afterFrame,
  };

  factory PmkitScrollSample.fromJson(Map<String, dynamic> json) =>
      PmkitScrollSample(
        atMs: json['atMs'] as int,
        offset: (json['offset'] as num).toDouble(),
        beforeFrame: json['beforeFrame'] as String?,
        afterFrame: json['afterFrame'] as String?,
      );
}

class PmkitEvent {
  const PmkitEvent({
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
  final PmkitStateAnchor? stateAnchor;
  final PmkitTargetAnchor? targetAnchor;
  final String? beforeFrame;
  final String? afterFrame;
  final PmkitInteractionResult? result;
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

  factory PmkitEvent.fromJson(Map<String, dynamic> json) => PmkitEvent(
    id: json['id'] as String,
    atMs: json['atMs'] as int,
    type: json['type'] as String,
    sessionId: json['sessionId'] as String?,
    stateAnchor: json['stateAnchor'] == null
        ? null
        : PmkitStateAnchor.fromJson(
            Map<String, dynamic>.from(json['stateAnchor'] as Map),
          ),
    targetAnchor: json['targetAnchor'] == null
        ? null
        : PmkitTargetAnchor.fromJson(
            Map<String, dynamic>.from(json['targetAnchor'] as Map),
          ),
    beforeFrame: json['beforeFrame'] as String?,
    afterFrame: json['afterFrame'] as String?,
    result: json['result'] == null
        ? null
        : PmkitInteractionResult.values.byName(json['result'] as String),
    relatedEventId: json['relatedEventId'] as String?,
    data: Map<String, Object?>.from(json['data'] as Map? ?? {}),
    explorationRunId: json['explorationRunId'] as String?,
    actionId: json['actionId'] as String?,
  );

  PmkitEvent withExplorationContext({
    String? sessionId,
    String? explorationRunId,
    String? actionId,
  }) => PmkitEvent(
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

class PmkitSession {
  PmkitSession({
    required this.id,
    required this.startedAt,
    required this.platform,
    required this.viewport,
  });

  final String id;
  final DateTime startedAt;
  final String platform;
  final PmkitRect viewport;

  final List<PmkitFrame> frames = [];
  final Map<String, Uint8List> frameBytes = {};
  final List<PmkitEvent> events = [];
  final List<PmkitScrollSample> scrollSamples = [];
  bool truncated = false;

  Size get viewportSize {
    if (viewport.width > 0 && viewport.height > 0) {
      return Size(viewport.width, viewport.height);
    }
    return const Size(390, 844);
  }

  PmkitFrame? frameById(String? id) {
    if (id == null) return null;
    for (final frame in frames) {
      if (frame.id == id) return frame;
    }
    return null;
  }

  PmkitFrame? latestSettledFrame() => frames.isEmpty ? null : frames.last;

  PmkitFrame? frameAtMs(int atMs) {
    PmkitFrame? latest;
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
    },
    'frames': frames.map((frame) => frame.toJson()).toList(),
    'events': events.map((event) => event.toJson()).toList(),
    if (scrollSamples.isNotEmpty)
      'scrollSamples': scrollSamples.map((s) => s.toJson()).toList(),
  };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  static PmkitSession fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 6) {
      throw const FormatException('Unsupported PMKit session schema version.');
    }
    final sessionJson = Map<String, dynamic>.from(json['session'] as Map);
    final viewportJson = Map<String, dynamic>.from(
      sessionJson['viewport'] as Map,
    );
    final session = PmkitSession(
      id: sessionJson['id'] as String,
      startedAt: DateTime.parse(sessionJson['startedAt'] as String),
      platform: sessionJson['platform'] as String,
      viewport: PmkitRect(
        (viewportJson['x'] as num).toDouble(),
        (viewportJson['y'] as num).toDouble(),
        (viewportJson['width'] as num).toDouble(),
        (viewportJson['height'] as num).toDouble(),
      ),
    )..truncated = sessionJson['truncated'] as bool? ?? false;

    session.frames.addAll(
      (json['frames'] as List<dynamic>? ?? []).map(
        (frame) => PmkitFrame.fromJson(Map<String, dynamic>.from(frame as Map)),
      ),
    );
    session.events.addAll(
      (json['events'] as List<dynamic>? ?? []).map(
        (event) => PmkitEvent.fromJson(Map<String, dynamic>.from(event as Map)),
      ),
    );
    session.scrollSamples.addAll(
      (json['scrollSamples'] as List<dynamic>? ?? []).map(
        (sample) => PmkitScrollSample.fromJson(
          Map<String, dynamic>.from(sample as Map),
        ),
      ),
    );
    return session;
  }
}
