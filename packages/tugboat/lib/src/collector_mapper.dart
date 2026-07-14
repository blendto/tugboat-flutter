import 'anchors.dart';
import 'collector_config.dart';
import 'models.dart';

Map<String, Object?> mapTugboatEventToCollectorEvent({
  required TugboatEvent event,
  required DateTime sessionStartedAt,
  required TugboatCollectorConfig collectorConfig,
  String? sessionId,
  String? userId,
}) {
  final triggeredAt = sessionStartedAt.add(Duration(milliseconds: event.atMs));

  final payload = <String, Object?>{
    ...event.data,
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
    if (event.explorationRunId != null)
      'explorationRunId': event.explorationRunId,
    if (event.actionId != null) 'actionId': event.actionId,
    if (event.beforeFrame != null) 'beforeFrame': event.beforeFrame,
    if (event.afterFrame != null) 'afterFrame': event.afterFrame,
    'stateAnchor': event.stateAnchor?.toJson() ?? <String, Object?>{},
    'targetAnchor': event.targetAnchor?.toJson() ?? <String, Object?>{},
    if (event.result != null) 'result': event.result!.name,
    'payload': payload,
    'build': collectorEventBuildIdentity(collectorConfig),
  };
}

/// Immutable build identity required for Context Graph matching.
Map<String, Object?> collectorEventBuildIdentity(TugboatCollectorConfig config) {
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
  };
}

/// Trailing digits from a tugboat frame id (`frame-12` → `12`).
/// Returns null when the id does not end in digits.
int? frameNumberFromId(String frameId) {
  final match = RegExp(r'(\d+)$').firstMatch(frameId);
  if (match == null) return null;
  return int.parse(match.group(1)!);
}
