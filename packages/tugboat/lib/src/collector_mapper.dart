import 'anchors.dart';
import 'collector_config.dart';
import 'models.dart';

/// Wire values for `POST /v1/sessions` `eventType`.
enum TugboatCollectorSessionEventType {
  sessionStart('session_start'),
  sessionIdentify('session_identify'),
  sessionEnd('session_end'),
  traitsUpdated('traits_updated'),
  userChanged('user_changed');

  const TugboatCollectorSessionEventType(this.wireValue);

  final String wireValue;
}

Map<String, Object?> mapTugboatEventToCollectorEvent({
  required TugboatEvent event,
  required DateTime sessionStartedAt,
  required TugboatCollectorConfig collectorConfig,
  String? sessionId,
  String? userId,
  String? traitsId,
}) {
  final triggeredAt = sessionStartedAt.add(Duration(milliseconds: event.atMs));

  final payload = <String, Object?>{
    ...event.data,
    'stream': event.stream.wireName,
    if (event.relatedEventId != null) 'relatedEventId': event.relatedEventId,
    if (event.explorationRunId != null)
      'explorationRunId': event.explorationRunId,
    if (event.actionId != null) 'actionId': event.actionId,
  };

  return {
    'id': event.id,
    'atMs': event.atMs,
    'triggeredAt': triggeredAt.toUtc().toIso8601String(),
    if (sessionId != null) 'sessionId': sessionId,
    'userId': userId,
    'eventType': event.type,
    'stream': event.stream.wireName,
    'enrichmentCandidate': tugboatEventIsEnrichmentCandidate(event),
    if (event.explorationRunId != null)
      'explorationRunId': event.explorationRunId,
    if (event.actionId != null) 'actionId': event.actionId,
    if (event.beforeFrame != null) 'beforeFrame': event.beforeFrame,
    if (event.afterFrame != null) 'afterFrame': event.afterFrame,
    if (traitsId != null) 'traitsId': traitsId,
    'stateAnchor': event.stateAnchor?.toJson() ?? <String, Object?>{},
    'targetAnchor': event.targetAnchor?.toJson() ?? <String, Object?>{},
    if (event.result != null) 'result': event.result!.name,
    'payload': payload,
    'build': collectorEventBuildIdentity(collectorConfig),
  };
}

/// Immutable build identity required for Context Graph matching.
Map<String, Object?> collectorEventBuildIdentity(
  TugboatCollectorConfig config,
) {
  return {
    'appId': config.appInfo.appId,
    'platform': config.deviceInfo.platform,
    'versionName': config.appInfo.version,
    'buildNumber': config.appInfo.buildNumber,
    'fingerprintSchemaVersion': tugboatFingerprintSchemaVersion,
  };
}

Map<String, Object?> mapTugboatSessionLifecycleToCollectorSession({
  required String eventType,
  required String sessionId,
  required DateTime triggeredAt,
  required TugboatCollectorConfig config,
  String? userId,
  Map<String, dynamic>? traits,
  String? traitsId,
}) {
  return {
    'sessionId': sessionId,
    'userId': userId ?? config.userId,
    'eventType': eventType,
    'triggeredAt': triggeredAt.toUtc().toIso8601String(),
    'platform': config.deviceInfo.platform,
    'fingerprintSchemaVersion': tugboatFingerprintSchemaVersion,
    'appInfo': config.appInfo.toJson(),
    'device': config.deviceInfo.toJson(),
    'ipInfo': config.ipInfo.toJson(),
    'locale': config.locale.toJson(),
    // Full traits bag wins over traitsId pass-through.
    if (traits != null) 'traits': traits,
    if (traits == null && traitsId != null) 'traitsId': traitsId,
  };
}

/// Trailing digits from a tugboat frame id (`frame-12` → `12`).
/// Returns null when the id does not end in digits.
int? frameNumberFromId(String frameId) {
  final match = RegExp(r'(\d+)$').firstMatch(frameId);
  if (match == null) return null;
  return int.parse(match.group(1)!);
}
