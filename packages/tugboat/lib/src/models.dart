import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'collector_config.dart';

/// Current session JSON schema.
///
/// Schema 10 removes serialized state identity, removes `state_change`, and
/// adds the `interaction` frame trigger.
const int tugboatSessionSchemaVersion = 10;

/// Event selection channel for enrichment / insight / replay consumers.
enum TugboatEventStream {
  /// Default enrichment stream — prefer `type: interaction`.
  semantic,

  /// Route/state/scroll/pointer observations linked to interactions.
  evidence,

  /// Capture health and support diagnostics.
  diagnostic;

  String get wireName => switch (this) {
    TugboatEventStream.semantic => 'semantic',
    TugboatEventStream.evidence => 'evidence',
    TugboatEventStream.diagnostic => 'diagnostic',
  };

  static TugboatEventStream parse(String? raw) {
    switch (raw) {
      case 'semantic':
        return TugboatEventStream.semantic;
      case 'evidence':
        return TugboatEventStream.evidence;
      case 'diagnostic':
        return TugboatEventStream.diagnostic;
      default:
        throw FormatException('Unsupported Tugboat event stream: $raw');
    }
  }
}

/// Wire strings for event streams.
const String tugboatEventStreamSemantic = 'semantic';
const String tugboatEventStreamEvidence = 'evidence';
const String tugboatEventStreamDiagnostic = 'diagnostic';

const int tugboatInteractionSchemaVersion = 2;
const int tugboatRouteChangeSchemaVersion = 2;

/// Closed set of `route_change.data.overlayKind` values.
abstract final class TugboatOverlayKind {
  static const page = 'page';
  static const sheet = 'sheet';
  static const dialog = 'dialog';
  static const popup = 'popup';
  static const unknown = 'unknown';
}

/// Maximum `route_change.data.routeStack` entries (bottom → top).
const int tugboatRouteStackMaxEntries = 16;

/// Split route identity for `route_change` (additive; `route` is unchanged).
class TugboatRouteIdentity {
  const TugboatRouteIdentity({
    required this.routeType,
    required this.routeNamed,
    this.route,
    this.routeName,
  });

  /// Wire `route` / `fromRoute`: `settings.name` if non-empty, else runtime type.
  final String? route;

  /// `settings.name` when non-empty; omit on the wire when null.
  final String? routeName;

  /// Always `route.runtimeType.toString()`.
  final String routeType;

  /// True iff `settings.name` is non-empty.
  final bool routeNamed;
}

/// Mechanical overlay classification from the route type and `is PopupRoute`.
String tugboatOverlayKindFor(Route<dynamic>? route) {
  if (route == null) return TugboatOverlayKind.unknown;
  final typeName = route.runtimeType.toString();
  if (_routeTypeLooksLikeSheet(typeName)) return TugboatOverlayKind.sheet;
  if (_routeTypeLooksLikeDialog(typeName)) return TugboatOverlayKind.dialog;
  if (route is PopupRoute) return TugboatOverlayKind.popup;
  if (route is PageRoute) return TugboatOverlayKind.page;
  return TugboatOverlayKind.unknown;
}

TugboatRouteIdentity tugboatRouteIdentityFor(Route<dynamic>? route) {
  if (route == null) {
    return const TugboatRouteIdentity(routeType: 'unknown', routeNamed: false);
  }
  final settingsName = route.settings.name;
  final named = settingsName != null && settingsName.isNotEmpty;
  final typeName = route.runtimeType.toString();
  return TugboatRouteIdentity(
    route: named ? settingsName : typeName,
    routeName: named ? settingsName : null,
    routeType: typeName,
    routeNamed: named,
  );
}

bool _routeTypeLooksLikeSheet(String typeName) =>
    typeName.contains('ModalBottomSheet') || typeName.contains('BottomSheet');

bool _routeTypeLooksLikeDialog(String typeName) => typeName.contains('Dialog');

/// Active application locale captured as evidence, never as fingerprint input.
class TugboatLocaleInfo {
  const TugboatLocaleInfo({
    required this.language,
    required this.tag,
    this.country,
    this.script,
  });

  factory TugboatLocaleInfo.fromLocale(Locale locale) => TugboatLocaleInfo(
    language: locale.languageCode,
    country: locale.countryCode,
    script: locale.scriptCode,
    tag: locale.toLanguageTag(),
  );

  final String language;
  final String? country;
  final String? script;
  final String tag;

  Map<String, Object?> toJson() => {
    'language': language,
    if (country != null && country!.isNotEmpty) 'country': country,
    if (script != null && script!.isNotEmpty) 'script': script,
    'tag': tag,
  };

  @override
  bool operator ==(Object other) =>
      other is TugboatLocaleInfo &&
      language == other.language &&
      country == other.country &&
      script == other.script &&
      tag == other.tag;

  @override
  int get hashCode => Object.hash(language, country, script, tag);
}

/// Whether [event] is a default enrichment / insight candidate.
bool tugboatEventIsEnrichmentCandidate(TugboatEvent event) {
  switch (event.stream) {
    case TugboatEventStream.diagnostic:
    case TugboatEventStream.evidence:
    case TugboatEventStream.semantic:
      return event.type == 'interaction';
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

/// `interaction` is a fresh, non-coalescing after-frame request for one
/// completed user interaction.
enum TugboatFrameTrigger {
  initial,
  tap,
  scroll,
  route,
  lifecycle,
  manual,
  interaction,
}

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
    this.captureSessionId,
    this.activationRequestId,
    this.targetAnchor,
    this.beforeFrame,
    this.afterFrame,
    this.result,
    this.relatedEventId,
    this.data = const {},
    this.locale,
    this.explorationRunId,
    this.actionId,
  });

  final String id;
  final int atMs;
  final String type;
  final TugboatEventStream stream;

  final String? captureSessionId;
  final String? activationRequestId;
  final TugboatTargetAnchor? targetAnchor;
  final String? beforeFrame;
  final String? afterFrame;
  final TugboatInteractionResult? result;
  final String? relatedEventId;
  final Map<String, Object?> data;
  final TugboatLocaleInfo? locale;
  final String? explorationRunId;
  final String? actionId;

  bool get isSemanticStream => stream == TugboatEventStream.semantic;

  bool get isEnrichmentCandidate => tugboatEventIsEnrichmentCandidate(this);

  Map<String, Object?> toJson() => {
    'id': id,
    'atMs': atMs,
    'type': type,
    'stream': stream.wireName,
    if (captureSessionId != null) 'captureSessionId': captureSessionId,
    if (activationRequestId != null) 'activationRequestId': activationRequestId,
    if (targetAnchor != null) 'targetAnchor': targetAnchor!.toJson(),
    if (beforeFrame != null) 'beforeFrame': beforeFrame,
    if (afterFrame != null) 'afterFrame': afterFrame,
    if (result != null) 'result': result!.name,
    if (relatedEventId != null) 'relatedEventId': relatedEventId,
    if (data.isNotEmpty) 'data': data,
    if (locale != null) 'locale': locale!.toJson(),
    if (explorationRunId != null) 'explorationRunId': explorationRunId,
    if (actionId != null) 'actionId': actionId,
  };

  TugboatEvent copyWith({
    String? id,
    int? atMs,
    String? type,
    TugboatEventStream? stream,
    String? captureSessionId,
    String? activationRequestId,
    TugboatTargetAnchor? targetAnchor,
    String? beforeFrame,
    String? afterFrame,
    TugboatInteractionResult? result,
    String? relatedEventId,
    Map<String, Object?>? data,
    TugboatLocaleInfo? locale,
    String? explorationRunId,
    String? actionId,
  }) {
    final core = _copyEventCore(this, id, atMs, type, stream, data, locale);
    return _copyEventContext(
      core,
      captureSessionId,
      activationRequestId,
      targetAnchor,
      beforeFrame,
      afterFrame,
      result,
      relatedEventId,
      explorationRunId,
      actionId,
    );
  }

  TugboatEvent withData(Map<String, Object?> updates) =>
      copyWith(data: {...data, ...updates});

  TugboatEvent withExplorationContext({
    String? captureSessionId,
    String? activationRequestId,
    String? explorationRunId,
    String? actionId,
  }) => copyWith(
    captureSessionId: captureSessionId ?? this.captureSessionId,
    activationRequestId: activationRequestId ?? this.activationRequestId,
    explorationRunId: explorationRunId ?? this.explorationRunId,
    actionId: actionId ?? this.actionId,
  );
}

TugboatEvent _copyEventCore(
  TugboatEvent source,
  String? id,
  int? atMs,
  String? type,
  TugboatEventStream? stream,
  Map<String, Object?>? data,
  TugboatLocaleInfo? locale,
) => TugboatEvent(
  id: id ?? source.id,
  atMs: atMs ?? source.atMs,
  type: type ?? source.type,
  stream: stream ?? source.stream,
  captureSessionId: source.captureSessionId,
  activationRequestId: source.activationRequestId,
  targetAnchor: source.targetAnchor,
  beforeFrame: source.beforeFrame,
  afterFrame: source.afterFrame,
  result: source.result,
  relatedEventId: source.relatedEventId,
  data: data ?? source.data,
  locale: locale ?? source.locale,
  explorationRunId: source.explorationRunId,
  actionId: source.actionId,
);

TugboatEvent _copyEventContext(
  TugboatEvent source,
  String? captureSessionId,
  String? activationRequestId,
  TugboatTargetAnchor? targetAnchor,
  String? beforeFrame,
  String? afterFrame,
  TugboatInteractionResult? result,
  String? relatedEventId,
  String? explorationRunId,
  String? actionId,
) => TugboatEvent(
  id: source.id,
  atMs: source.atMs,
  type: source.type,
  stream: source.stream,
  captureSessionId: captureSessionId ?? source.captureSessionId,
  activationRequestId: activationRequestId ?? source.activationRequestId,
  targetAnchor: targetAnchor ?? source.targetAnchor,
  beforeFrame: beforeFrame ?? source.beforeFrame,
  afterFrame: afterFrame ?? source.afterFrame,
  result: result ?? source.result,
  relatedEventId: relatedEventId ?? source.relatedEventId,
  data: source.data,
  locale: source.locale,
  explorationRunId: explorationRunId ?? source.explorationRunId,
  actionId: actionId ?? source.actionId,
);

class TugboatSession {
  TugboatSession({
    required this.id,
    required this.startedAt,
    required this.platform,
    required this.viewport,
    this.appInfo,
    this.locale,
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
  TugboatLocaleInfo? locale;

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
      if (locale != null) 'locale': locale!.toJson(),
    },
    'frames': frames.map((frame) => frame.toJson()).toList(),
    'events': events.map((event) => event.toJson()).toList(),
    if (scrollSamples.isNotEmpty)
      'scrollSamples': scrollSamples.map((s) => s.toJson()).toList(),
  };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}
