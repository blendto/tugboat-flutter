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

  if (event.type == 'interaction') {
    final data = event.data;
    return _collectorFlatEnvelope(
      event: event,
      triggeredAt: triggeredAt,
      collectorConfig: collectorConfig,
      sessionId: sessionId,
      userId: userId,
      traitsId: traitsId,
      extra: {
        'interactionSchema':
            data['interactionSchema'] ?? tugboatInteractionSchemaVersion,
        if (data['route'] != null) 'route': data['route'],
        if (data['targetFingerprint'] != null)
          'targetFingerprint': data['targetFingerprint'],
        if (data['gesture'] != null) 'gesture': data['gesture'],
        if (data['payload'] != null) 'payload': data['payload'],
      },
    );
  }

  if (event.type == 'route_change') {
    final data = event.data;
    return _collectorFlatEnvelope(
      event: event,
      triggeredAt: triggeredAt,
      collectorConfig: collectorConfig,
      sessionId: sessionId,
      userId: userId,
      traitsId: traitsId,
      extra: {
        'routeChangeSchema': tugboatRouteChangeSchemaVersion,
        if (data['fromRoute'] != null) 'fromRoute': data['fromRoute'],
        if (data['route'] != null) 'route': data['route'],
        if (data['navigation'] != null) 'navigation': data['navigation'],
      },
    );
  }

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
    'stream': event.stream.wireName,
    'enrichmentCandidate': tugboatEventIsEnrichmentCandidate(event),
    if (event.explorationRunId != null)
      'explorationRunId': event.explorationRunId,
    if (event.actionId != null) 'actionId': event.actionId,
    if (event.beforeFrame != null) 'beforeFrame': event.beforeFrame,
    if (event.afterFrame != null) 'afterFrame': event.afterFrame,
    if (traitsId != null) 'traitsId': traitsId,
    if (event.targetAnchor != null)
      'targetAnchor': event.targetAnchor!.toJson(),
    if (event.result != null) 'result': event.result!.name,
    'payload': payload,
    'build': collectorEventBuildIdentity(collectorConfig),
  };
}

/// Shared flat collector envelope for schema-v2 production events.
Map<String, Object?> _collectorFlatEnvelope({
  required TugboatEvent event,
  required DateTime triggeredAt,
  required TugboatCollectorConfig collectorConfig,
  String? sessionId,
  String? userId,
  String? traitsId,
  required Map<String, Object?> extra,
}) {
  return {
    'id': event.id,
    'atMs': event.atMs,
    'triggeredAt': triggeredAt.toUtc().toIso8601String(),
    if (sessionId != null) 'sessionId': sessionId,
    'userId': userId,
    'eventType': event.type,
    'stream': event.stream.wireName,
    'enrichmentCandidate': tugboatEventIsEnrichmentCandidate(event),
    ...extra,
    if (event.relatedEventId != null) 'relatedEventId': event.relatedEventId,
    if (event.beforeFrame != null) 'beforeFrame': event.beforeFrame,
    if (event.afterFrame != null) 'afterFrame': event.afterFrame,
    if (event.explorationRunId != null)
      'explorationRunId': event.explorationRunId,
    if (event.actionId != null) 'actionId': event.actionId,
    if (traitsId != null) 'traitsId': traitsId,
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
  final isSessionStart =
      eventType == TugboatCollectorSessionEventType.sessionStart.wireValue;
  final carriesUserId =
      isSessionStart ||
      eventType == TugboatCollectorSessionEventType.sessionIdentify.wireValue ||
      eventType == TugboatCollectorSessionEventType.userChanged.wireValue;
  final carriesTraits =
      isSessionStart ||
      eventType == TugboatCollectorSessionEventType.sessionIdentify.wireValue ||
      eventType == TugboatCollectorSessionEventType.traitsUpdated.wireValue;

  final body = <String, Object?>{
    'sessionId': sessionId,
    'eventType': eventType,
    'triggeredAt': triggeredAt.toUtc().toIso8601String(),
  };

  if (carriesUserId) {
    // Only session_start inherits the configured startup identity. Later
    // lifecycle records use null as an explicit identity-clear operation.
    body['userId'] = isSessionStart ? userId ?? config.userId : userId;
  }
  if (isSessionStart) {
    final appInfo = Map<String, Object?>.from(config.appInfo.toJson())
      ..remove('installationId')
      ..remove('name');
    body.addAll({
      'appInfo': appInfo,
      'device': config.deviceInfo.toJson(),
      'ipInfo': config.ipInfo.toJson(),
      'locale': config.locale.toJson(),
    });
  }
  if (carriesTraits) {
    // Full traits bag wins over traitsId pass-through.
    if (traits != null) body['traits'] = traits;
    if (traits == null && traitsId != null) body['traitsId'] = traitsId;
  }
  return body;
}

/// Trailing digits from a tugboat frame id (`frame-12` → `12`).
/// Returns null when the id does not end in digits.
int? frameNumberFromId(String frameId) {
  final match = RegExp(r'(\d+)$').firstMatch(frameId);
  if (match == null) return null;
  return int.parse(match.group(1)!);
}
