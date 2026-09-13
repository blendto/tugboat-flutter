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
    final targetAnchor = _collectorInteractionTargetAnchor(event.targetAnchor);
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
        if (data['fingerprintConfidence'] != null)
          'fingerprintConfidence': data['fingerprintConfidence'],
        if (data['targetResolutionFailureReason'] != null)
          'targetResolutionFailureReason':
              data['targetResolutionFailureReason'],
        if (data['gesture'] != null) 'gesture': data['gesture'],
        if (data['payload'] != null) 'payload': data['payload'],
        if (targetAnchor != null) 'targetAnchor': targetAnchor,
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
      extra: _routeChangeCollectorExtra(data),
    );
  }

  if (event.type == 'network_call') {
    return _collectorGenericEnvelope(
      event: event,
      triggeredAt: triggeredAt,
      collectorConfig: collectorConfig,
      sessionId: sessionId,
      userId: userId,
      traitsId: traitsId,
      payload: _networkCallCollectorPayload(
        event.data,
        stream: event.stream.wireName,
      ),
    );
  }

  final payload = <String, Object?>{
    ...event.data,
    if (event.relatedEventId != null) 'relatedEventId': event.relatedEventId,
    if (event.explorationRunId != null)
      'explorationRunId': event.explorationRunId,
    if (event.actionId != null) 'actionId': event.actionId,
  };

  return _collectorGenericEnvelope(
    event: event,
    triggeredAt: triggeredAt,
    collectorConfig: collectorConfig,
    sessionId: sessionId,
    userId: userId,
    traitsId: traitsId,
    payload: payload,
  );
}

Map<String, Object?> _collectorGenericEnvelope({
  required TugboatEvent event,
  required DateTime triggeredAt,
  required TugboatCollectorConfig collectorConfig,
  String? sessionId,
  String? userId,
  String? traitsId,
  required Map<String, Object?> payload,
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
    if (event.explorationRunId != null)
      'explorationRunId': event.explorationRunId,
    if (event.actionId != null) 'actionId': event.actionId,
    if (event.locale != null) 'locale': event.locale!.toJson(),
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

Map<String, Object?>? _collectorInteractionTargetAnchor(
  TugboatTargetAnchor? anchor,
) {
  if (anchor == null) return null;
  final payload = <String, Object?>{
    if (anchor.fingerprint != null && anchor.fingerprint!.isNotEmpty)
      'fingerprint': anchor.fingerprint,
    if (anchor.canonicalPath != null && anchor.canonicalPath!.isNotEmpty)
      'canonicalPath': anchor.canonicalPath,
    if (anchor.widgetType != null) 'widgetType': anchor.widgetType,
    if (anchor.role != null) 'role': anchor.role,
    if (anchor.fingerprintConfidence != null &&
        anchor.fingerprintConfidence!.isNotEmpty)
      'fingerprintConfidence': anchor.fingerprintConfidence,
    if (anchor.tagFingerprint != null && anchor.tagFingerprint!.isNotEmpty)
      'tagFingerprint': anchor.tagFingerprint,
    if (anchor.relativePosition != null)
      'relativePosition': anchor.relativePosition,
    if (anchor.enabled != null) 'enabled': anchor.enabled,
    if (anchor.actions.isNotEmpty) 'actions': anchor.actions,
  };
  return payload.isEmpty ? null : payload;
}

Map<String, Object?> _networkCallCollectorPayload(
  Map<String, Object?> data, {
  required String stream,
}) {
  final outcome = data['outcome'];
  final payload = <String, Object?>{
    if (data['method'] is String) 'method': data['method'],
    if (data['route'] is String) 'route': data['route'],
    if (outcome == 'response' &&
        data['statusCode'] is int &&
        (data['statusCode'] as int) >= 100 &&
        (data['statusCode'] as int) <= 599)
      'statusCode': data['statusCode'],
    if (outcome is String &&
        const {'response', 'network_error', 'cancelled'}.contains(outcome))
      'outcome': outcome,
    if (data['durationMs'] is int) 'durationMs': data['durationMs'],
    if (data['attemptCount'] is int && (data['attemptCount'] as int) > 0)
      'attemptCount': data['attemptCount'],
    'stream': stream,
  };
  return payload;
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
    if (event.locale != null) 'locale': event.locale!.toJson(),
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
  required DateTime sessionStartedAt,
  required DateTime triggeredAt,
  required TugboatCollectorConfig config,
  String? userId,
  Map<String, dynamic>? traits,
  String? traitsId,
  TugboatLocaleInfo? activeLocale,
}) {
  final isSessionStart = _isSessionStart(eventType);

  final body = <String, Object?>{
    'sessionId': sessionId,
    'eventType': eventType,
    'atMs': triggeredAt.difference(sessionStartedAt).inMilliseconds,
    'triggeredAt': triggeredAt.toUtc().toIso8601String(),
    // Only session_start inherits the configured startup identity. Later
    // lifecycle records send the runtime id as-is, including null.
    'userId': isSessionStart ? userId ?? config.userId : userId,
  };

  if (isSessionStart) {
    final appInfo = Map<String, Object?>.from(config.appInfo.toJson())
      ..remove('installationId')
      ..remove('name');
    final locale = Map<String, Object?>.from(config.locale.toJson());
    if (activeLocale != null) {
      locale
        ..remove('language')
        ..remove('country')
        ..remove('script')
        ..remove('tag')
        ..addAll(activeLocale.toJson());
    }
    body.addAll({
      'appInfo': appInfo,
      'device': config.deviceInfo.toJson(),
      'ipInfo': config.ipInfo.toJson(),
      'locale': locale,
    });
  }
  // Full traits bag wins over traitsId pass-through.
  if (traits != null) body['traits'] = traits;
  if (traits == null && traitsId != null) body['traitsId'] = traitsId;
  return body;
}

bool _isSessionStart(String eventType) =>
    eventType == TugboatCollectorSessionEventType.sessionStart.wireValue;

/// Trailing digits from a tugboat frame id (`frame-12` → `12`).
/// Returns null when the id does not end in digits.
int? frameNumberFromId(String frameId) {
  final match = RegExp(r'(\d+)$').firstMatch(frameId);
  if (match == null) return null;
  return int.parse(match.group(1)!);
}

const _routeChangeCollectorKeys = <String>[
  'fromRoute',
  'route',
  'navigation',
  'causeEventId',
  'causedByInteractionId',
  'routeName',
  'routeType',
  'routeNamed',
  'fromRouteName',
  'fromRouteType',
  'fromRouteNamed',
  'overlayKind',
  'presentedOverRoute',
  'presentedOverRouteInstanceId',
  'presentedOverOverlayKind',
  'hostPageRoute',
  'hostPageRouteInstanceId',
  'routeStack',
  'causeTargetFingerprint',
  'causeGesture',
];

Map<String, Object?> _routeChangeCollectorExtra(Map<String, Object?> data) {
  final extra = <String, Object?>{
    'routeChangeSchema': tugboatRouteChangeSchemaVersion,
  };
  _copyPresentRouteChangeKeys(extra, data);
  if (data['routeStackTruncated'] == true) {
    extra['routeStackTruncated'] = true;
  }
  return extra;
}

void _copyPresentRouteChangeKeys(
  Map<String, Object?> extra,
  Map<String, Object?> data,
) {
  for (final key in _routeChangeCollectorKeys) {
    final value = data[key];
    if (value != null) extra[key] = value;
  }
}
