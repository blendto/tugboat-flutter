import 'package:tugboat/tugboat.dart';

/// Test-only deserializers. The runtime SDK only emits JSON.
extension TugboatNormalizedBoundsTestJson on TugboatNormalizedBounds {
  static TugboatNormalizedBounds fromJson(Map<String, dynamic> json) =>
      TugboatNormalizedBounds(
        left: (json['left'] as num).toDouble(),
        top: (json['top'] as num).toDouble(),
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
      );
}

extension TugboatTargetAnchorTestJson on TugboatTargetAnchor {
  static TugboatTargetAnchor fromJson(Map<String, dynamic> json) =>
      TugboatTargetAnchor(
        schemaVersion: json['schemaVersion'] as int? ?? 1,
        widgetType: json['widgetType'] as String?,
        role: json['role'] as String?,
        fingerprint: json['fingerprint'] as String?,
        fingerprintConfidence: json['fingerprintConfidence'] as String?,
        tagFingerprint: json['tagFingerprint'] as String?,
        fingerprintParts: json['fingerprintParts'] == null
            ? const {}
            : Map<String, String>.from(json['fingerprintParts'] as Map),
        canonicalPath: json['canonicalPath'] as String?,
        relativePosition: json['relativePosition'] as String?,
        enabled: json['enabled'] as bool?,
        actions: (json['actions'] as List<dynamic>? ?? [])
            .cast<String>()
            .toList(),
      );
}

extension TugboatFrameTestJson on TugboatFrame {
  static TugboatFrame fromJson(Map<String, dynamic> json) => TugboatFrame(
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

extension TugboatScrollSampleTestJson on TugboatScrollSample {
  static TugboatScrollSample fromJson(Map<String, dynamic> json) =>
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

extension TugboatEventTestJson on TugboatEvent {
  static TugboatEvent fromJson(Map<String, dynamic> json) => TugboatEvent(
    id: json['id'] as String,
    atMs: json['atMs'] as int,
    type: json['type'] as String,
    stream: TugboatEventStream.parse(json['stream'] as String?),
    captureSessionId: json['captureSessionId'] as String?,
    activationRequestId: json['activationRequestId'] as String?,
    targetAnchor: json['targetAnchor'] == null
        ? null
        : TugboatTargetAnchorTestJson.fromJson(
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
}

extension TugboatSessionTestJson on TugboatSession {
  static TugboatSession fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'] as int?;
    if (version != 10) {
      throw const FormatException(
        'Unsupported Tugboat session schema version.',
      );
    }
    final sessionJson = Map<String, dynamic>.from(json['session'] as Map);
    final viewportJson = Map<String, dynamic>.from(
      sessionJson['viewport'] as Map,
    );
    final appInfoJson = sessionJson['appInfo'];
    final session = TugboatSession(
      id: sessionJson['captureSessionId'] as String,
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
              appId: appInfoJson['appId'] as String,
            ),
      activationRequestId: sessionJson['activationRequestId'] as String?,
      explorationRunId: sessionJson['explorationRunId'] as String?,
      collectorSessionId: sessionJson['collectorSessionId'] as String?,
    )..truncated = sessionJson['truncated'] as bool? ?? false;

    session.frames.addAll(
      (json['frames'] as List<dynamic>? ?? []).map(
        (frame) => TugboatFrameTestJson.fromJson(
          Map<String, dynamic>.from(frame as Map),
        ),
      ),
    );
    session.events.addAll(
      (json['events'] as List<dynamic>? ?? []).map(
        (event) => TugboatEventTestJson.fromJson(
          Map<String, dynamic>.from(event as Map),
        ),
      ),
    );
    session.scrollSamples.addAll(
      (json['scrollSamples'] as List<dynamic>? ?? []).map(
        (sample) => TugboatScrollSampleTestJson.fromJson(
          Map<String, dynamic>.from(sample as Map),
        ),
      ),
    );
    return session;
  }
}
