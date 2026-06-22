import 'collector_config.dart';
import 'models.dart';

Map<String, Object?> mapPmkitEventToCollectorEvent({
  required PmkitEvent event,
  required String sessionId,
  required DateTime sessionStartedAt,
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
    'sessionId': sessionId,
    'userId': userId,
    'eventType': event.type,
    if (event.beforeFrame != null) 'beforeFrame': event.beforeFrame,
    if (event.afterFrame != null) 'afterFrame': event.afterFrame,
    'stateAnchor': event.stateAnchor?.toJson() ?? <String, Object?>{},
    'targetAnchor': event.targetAnchor?.toJson() ?? <String, Object?>{},
    if (event.result != null) 'result': event.result!.name,
    'payload': payload,
  };
}

Map<String, Object?> mapPmkitSessionLifecycleToCollectorSession({
  required String eventType,
  required String sessionId,
  required DateTime triggeredAt,
  required PmkitCollectorConfig config,
  String? userId,
}) {
  return {
    'sessionId': sessionId,
    'userId': userId ?? config.userId,
    'eventType': eventType,
    'triggeredAt': triggeredAt.toUtc().toIso8601String(),
    'appInfo': config.appInfo.toJson(),
    'device': config.deviceInfo.toJson(),
    'ipInfo': config.ipInfo.toJson(),
    'locale': config.locale.toJson(),
  };
}

int frameNumberFromId(String frameId) {
  final match = RegExp(r'(\d+)$').firstMatch(frameId);
  if (match == null) {
    return 0;
  }
  return int.parse(match.group(1)!);
}
