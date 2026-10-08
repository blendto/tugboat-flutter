// Loader and evaluator for the language-neutral golden fixtures in
// `<repo>/conformance/`. See `conformance/README.md` for the format.
//
// This file only reads fixtures. Nothing here writes to `conformance/`.
import 'dart:convert';
import 'dart:io';

import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_mapper.dart';
import 'package:tugboat/src/models.dart';

/// Version of the fixture file envelope itself (not of the SDK contracts).
const int conformanceFixtureFormat = 1;

enum ConformanceKind {
  identityParts('fingerprint.identityParts', 'fingerprint/identity_parts'),
  labelHash('fingerprint.labelHash', 'fingerprint/label_hash'),
  collectorEvent('collector.event', 'collector/event'),
  sessionLifecycle('collector.sessionLifecycle', 'collector/session_lifecycle');

  const ConformanceKind(this.wireName, this.directory);

  final String wireName;
  final String directory;

  static ConformanceKind parse(Object? raw) {
    for (final kind in values) {
      if (kind.wireName == raw) return kind;
    }
    throw FormatException('Unknown fixture kind: $raw');
  }
}

class ConformanceFixture {
  const ConformanceFixture({
    required this.relativePath,
    required this.kind,
    required this.name,
    required this.contract,
    required this.input,
    required this.expected,
  });

  final String relativePath;
  final ConformanceKind kind;
  final String name;
  final Map<String, Object?> contract;
  final Map<String, Object?> input;
  final Map<String, Object?> expected;
}

/// Walks up from the working directory to the repo's `conformance/` folder.
Directory findConformanceRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = Directory('${dir.path}/conformance');
    if (File('${candidate.path}/README.md').existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('conformance/ not found above ${Directory.current}');
    }
    dir = parent;
  }
}

/// Every `*.json` fixture under [root], sorted by relative path.
List<File> listFixtureFiles(Directory root) {
  final files = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

String fixtureRelativePath(Directory root, File file) =>
    file.path.substring(root.path.length + 1).replaceAll(r'\', '/');

const _envelopeKeys = {
  'fixtureFormat',
  'kind',
  'name',
  'description',
  'contract',
  'input',
  'expected',
};

ConformanceFixture loadFixture(Directory root, File file) {
  final relativePath = fixtureRelativePath(root, file);
  final json = _object(jsonDecode(file.readAsStringSync()), relativePath);
  _checkKeys(json, _envelopeKeys, relativePath);
  if (json['fixtureFormat'] != conformanceFixtureFormat) {
    throw FormatException('$relativePath: unsupported fixtureFormat');
  }
  _requireString(json, 'description', relativePath);
  return ConformanceFixture(
    relativePath: relativePath,
    kind: ConformanceKind.parse(json['kind']),
    name: _requireString(json, 'name', relativePath),
    contract: _object(json['contract'], '$relativePath.contract'),
    input: _object(json['input'], '$relativePath.input'),
    expected: _object(json['expected'], '$relativePath.expected'),
  );
}

/// Runs the current Dart implementation on [fixture.input] and returns the
/// value to compare against [fixture.expected].
Map<String, Object?> evaluateFixture(ConformanceFixture fixture) {
  final input = fixture.input;
  switch (fixture.kind) {
    case ConformanceKind.identityParts:
      return _evaluateIdentityParts(input);
    case ConformanceKind.labelHash:
      _checkKeys(input, const {'value'}, 'input');
      return {
        'hash': tugboatLabelHash(_requireString(input, 'value', 'input')),
      };
    case ConformanceKind.collectorEvent:
      return _evaluateCollectorEvent(input);
    case ConformanceKind.sessionLifecycle:
      return _evaluateSessionLifecycle(input);
  }
}

// --------------------------------------------------------------- fingerprint

/// Mirror of the library-private `_fingerprintForParts` canonical string:
/// parts sorted by key ([String.compareTo], UTF-16 code units), each written
/// as `key=value`, joined with `|`. The conformance test binds this mirror to
/// the real resolver output, so drift fails there.
String conformanceCanonicalIdentityString(
  List<MapEntry<String, String>> parts,
) {
  final sorted = [...parts]..sort((a, b) => a.key.compareTo(b.key));
  return sorted.map((entry) => '${entry.key}=${entry.value}').join('|');
}

/// `''` for no parts, else [tugboatLabelHash] of the canonical string.
String conformanceIdentityFingerprint(List<MapEntry<String, String>> parts) {
  if (parts.isEmpty) return '';
  return tugboatLabelHash(conformanceCanonicalIdentityString(parts));
}

Map<String, Object?> _evaluateIdentityParts(Map<String, Object?> input) {
  _checkKeys(input, const {'parts'}, 'input');
  final rawParts = _list(input['parts'], 'input.parts');
  final parts = <MapEntry<String, String>>[];
  final seen = <String>{};
  for (final raw in rawParts) {
    final pair = _list(raw, 'input.parts[]');
    if (pair.length != 2 || pair[0] is! String || pair[1] is! String) {
      throw const FormatException('input.parts[] must be [key, value]');
    }
    if (!seen.add(pair[0] as String)) {
      throw FormatException('input.parts duplicate key ${pair[0]}');
    }
    parts.add(MapEntry(pair[0] as String, pair[1] as String));
  }
  return {
    'canonicalString': conformanceCanonicalIdentityString(parts),
    'fingerprint': conformanceIdentityFingerprint(parts),
  };
}

// ----------------------------------------------------------------- collector

Map<String, Object?> _evaluateCollectorEvent(Map<String, Object?> input) {
  _checkKeys(input, const {'host', 'session', 'event'}, 'input');
  final config = _decodeHost(_object(input['host'], 'input.host'));
  final session = _decodeSession(_object(input['session'], 'input.session'));
  if (session.traits != null) {
    throw const FormatException('input.session.traits: lifecycle only');
  }
  final record = mapTugboatEventToCollectorEvent(
    event: _decodeEvent(_object(input['event'], 'input.event')),
    sessionStartedAt: session.startedAt,
    collectorConfig: config,
    sessionId: session.sessionId,
    userId: session.userId,
    traitsId: session.traitsId,
  );
  return {'record': record};
}

Map<String, Object?> _evaluateSessionLifecycle(Map<String, Object?> input) {
  _checkKeys(input, const {'host', 'session', 'lifecycle'}, 'input');
  final config = _decodeHost(_object(input['host'], 'input.host'));
  final session = _decodeSession(_object(input['session'], 'input.session'));
  final lifecycle = _object(input['lifecycle'], 'input.lifecycle');
  _checkKeys(lifecycle, const {
    'eventType',
    'triggeredAtEpochMs',
    'activeLocale',
  }, 'input.lifecycle');
  final sessionId = session.sessionId;
  if (sessionId == null) {
    throw const FormatException('input.session.sessionId: required');
  }
  final record = mapTugboatSessionLifecycleToCollectorSession(
    eventType: _requireString(lifecycle, 'eventType', 'input.lifecycle'),
    sessionId: sessionId,
    sessionStartedAt: session.startedAt,
    triggeredAt: _epochMs(lifecycle, 'triggeredAtEpochMs', 'input.lifecycle'),
    config: config,
    userId: session.userId,
    traits: session.traits,
    traitsId: session.traitsId,
    activeLocale: _decodeLocale(lifecycle['activeLocale'], 'activeLocale'),
  );
  return {'record': record};
}

typedef _Session = ({
  String? sessionId,
  DateTime startedAt,
  String? userId,
  String? traitsId,
  Map<String, dynamic>? traits,
});

_Session _decodeSession(Map<String, Object?> json) {
  const where = 'input.session';
  _checkKeys(json, const {
    'sessionId',
    'startedAtEpochMs',
    'userId',
    'traitsId',
    'traits',
  }, where);
  final traits = json['traits'];
  return (
    sessionId: _optString(json, 'sessionId', where),
    startedAt: _epochMs(json, 'startedAtEpochMs', where),
    userId: _optString(json, 'userId', where),
    traitsId: _optString(json, 'traitsId', where),
    traits: traits == null
        ? null
        : Map<String, dynamic>.from(_object(traits, '$where.traits')),
  );
}

TugboatCollectorConfig _decodeHost(Map<String, Object?> json) {
  const where = 'input.host';
  _checkKeys(json, const {
    'app',
    'device',
    'ip',
    'locale',
    'configuredUserId',
  }, where);
  return TugboatCollectorConfig(
    // Transport settings are not mapping inputs.
    baseUrl: 'https://collector.invalid',
    apiKey: 'conformance',
    appInfo: _decodeApp(_object(json['app'], '$where.app')),
    deviceInfo: _decodeDevice(_object(json['device'], '$where.device')),
    ipInfo: _decodeIp(_object(json['ip'], '$where.ip')),
    locale: _decodeConfiguredLocale(_object(json['locale'], '$where.locale')),
    userId: _optString(json, 'configuredUserId', where),
  );
}

TugboatCollectorAppInfo _decodeApp(Map<String, Object?> json) {
  const where = 'input.host.app';
  _checkKeys(json, const {
    'name',
    'version',
    'buildNumber',
    'installationId',
    'appId',
  }, where);
  return TugboatCollectorAppInfo(
    name: _requireString(json, 'name', where),
    version: _requireString(json, 'version', where),
    buildNumber: _requireString(json, 'buildNumber', where),
    installationId: _requireString(json, 'installationId', where),
    appId: _requireString(json, 'appId', where),
  );
}

const _deviceKeys = {
  'id',
  'platform',
  'manufacturer',
  'model',
  'osVersion',
  'batteryPercent',
  'storageFreeMb',
  'ramMb',
  'networkType',
  'screenSize',
  'screenDensity',
  'screenDpi',
  'screenPixelDensity',
};

TugboatCollectorDeviceInfo _decodeDevice(Map<String, Object?> json) {
  const where = 'input.host.device';
  _checkKeys(json, _deviceKeys, where);
  final screen = _object(json['screenSize'], '$where.screenSize');
  _checkKeys(screen, const {'width', 'height'}, '$where.screenSize');
  return TugboatCollectorDeviceInfo(
    id: _requireString(json, 'id', where),
    platform: _requireString(json, 'platform', where),
    manufacturer: _optString(json, 'manufacturer', where),
    model: _optString(json, 'model', where),
    osVersion: _optString(json, 'osVersion', where),
    batteryPercent: _optInt(json, 'batteryPercent', where),
    storageFreeMb: _optInt(json, 'storageFreeMb', where),
    ramMb: _optInt(json, 'ramMb', where),
    networkType: _optString(json, 'networkType', where),
    screenSize: TugboatCollectorScreenSize(
      width: _requireDouble(screen, 'width', '$where.screenSize'),
      height: _requireDouble(screen, 'height', '$where.screenSize'),
    ),
    screenDensity: _requireDouble(json, 'screenDensity', where),
    screenDpi: _requireInt(json, 'screenDpi', where),
    screenPixelDensity: _requireDouble(json, 'screenPixelDensity', where),
  );
}

TugboatCollectorIpInfo _decodeIp(Map<String, Object?> json) {
  const where = 'input.host.ip';
  _checkKeys(json, const {
    'ip',
    'city',
    'region',
    'country',
    'timezone',
    'isp',
    'org',
  }, where);
  return TugboatCollectorIpInfo(
    ip: _requireString(json, 'ip', where),
    city: _optString(json, 'city', where),
    region: _optString(json, 'region', where),
    country: _optString(json, 'country', where),
    timezone: _optString(json, 'timezone', where),
    isp: _optString(json, 'isp', where),
    org: _optString(json, 'org', where),
  );
}

TugboatCollectorLocaleInfo _decodeConfiguredLocale(Map<String, Object?> json) {
  const where = 'input.host.locale';
  _checkKeys(json, const {'language', 'country', 'timezone'}, where);
  return TugboatCollectorLocaleInfo(
    language: _optString(json, 'language', where),
    country: _optString(json, 'country', where),
    timezone: _optString(json, 'timezone', where),
  );
}

TugboatLocaleInfo? _decodeLocale(Object? raw, String where) {
  if (raw == null) return null;
  final json = _object(raw, where);
  _checkKeys(json, const {'language', 'country', 'script', 'tag'}, where);
  return TugboatLocaleInfo(
    language: _requireString(json, 'language', where),
    country: _optString(json, 'country', where),
    script: _optString(json, 'script', where),
    tag: _requireString(json, 'tag', where),
  );
}

const _eventKeys = {
  'id',
  'atMs',
  'type',
  'stream',
  'targetAnchor',
  'beforeFrame',
  'afterFrame',
  'result',
  'relatedEventId',
  'data',
  'locale',
  'explorationRunId',
  'actionId',
};

TugboatEvent _decodeEvent(Map<String, Object?> json) {
  const where = 'input.event';
  _checkKeys(json, _eventKeys, where);
  final anchor = json['targetAnchor'];
  final result = _optString(json, 'result', where);
  return TugboatEvent(
    id: _requireString(json, 'id', where),
    atMs: _requireInt(json, 'atMs', where),
    type: _requireString(json, 'type', where),
    stream: TugboatEventStream.parse(_requireString(json, 'stream', where)),
    targetAnchor: anchor == null
        ? null
        : _decodeAnchor(_object(anchor, '$where.targetAnchor')),
    beforeFrame: _optString(json, 'beforeFrame', where),
    afterFrame: _optString(json, 'afterFrame', where),
    result: result == null
        ? null
        : TugboatInteractionResult.values.byName(result),
    relatedEventId: _optString(json, 'relatedEventId', where),
    data: json['data'] == null
        ? const {}
        : _object(json['data'], '$where.data'),
    locale: _decodeLocale(json['locale'], '$where.locale'),
    explorationRunId: _optString(json, 'explorationRunId', where),
    actionId: _optString(json, 'actionId', where),
  );
}

const _anchorKeys = {
  'schemaVersion',
  'widgetType',
  'role',
  'fingerprint',
  'fingerprintConfidence',
  'tagFingerprint',
  'fingerprintParts',
  'canonicalPath',
  'relativePosition',
  'enabled',
  'actions',
};

TugboatTargetAnchor _decodeAnchor(Map<String, Object?> json) {
  const where = 'input.event.targetAnchor';
  _checkKeys(json, _anchorKeys, where);
  final parts = json['fingerprintParts'];
  final actions = json['actions'];
  return TugboatTargetAnchor(
    schemaVersion: _optInt(json, 'schemaVersion', where) ?? 1,
    widgetType: _optString(json, 'widgetType', where),
    role: _optString(json, 'role', where),
    fingerprint: _optString(json, 'fingerprint', where),
    fingerprintConfidence: _optString(json, 'fingerprintConfidence', where),
    tagFingerprint: _optString(json, 'tagFingerprint', where),
    fingerprintParts: parts == null
        ? const {}
        : Map<String, String>.from(_object(parts, '$where.fingerprintParts')),
    canonicalPath: _optString(json, 'canonicalPath', where),
    relativePosition: _optString(json, 'relativePosition', where),
    enabled: _optBool(json, 'enabled', where),
    actions: actions == null
        ? const []
        : _list(actions, '$where.actions').cast<String>(),
  );
}

// -------------------------------------------------------------- comparison

/// Type-strict deep JSON comparison. Object key order is ignored; an absent
/// key differs from a `null` value; an integer differs from a double with the
/// same value (Dart encodes `390.0`, not `390`). Returns one line per
/// mismatch, empty when equal.
List<String> diffJson(Object? expected, Object? actual, [String path = r'$']) {
  if (expected is Map && actual is Map) {
    return _diffObjects(expected, actual, path);
  }
  if (expected is List && actual is List) {
    return _diffArrays(expected, actual, path);
  }
  if (_sameScalar(expected, actual)) return const [];
  return [
    '$path: expected ${_describe(expected)}, actual ${_describe(actual)}',
  ];
}

List<String> _diffObjects(Map expected, Map actual, String path) {
  final out = <String>[];
  for (final key in expected.keys) {
    if (!actual.containsKey(key)) {
      out.add('$path.$key: missing in actual');
    } else {
      out.addAll(diffJson(expected[key], actual[key], '$path.$key'));
    }
  }
  for (final key in actual.keys) {
    if (!expected.containsKey(key)) out.add('$path.$key: unexpected in actual');
  }
  return out;
}

List<String> _diffArrays(List expected, List actual, String path) {
  if (expected.length != actual.length) {
    return [
      '$path: expected ${expected.length} items, actual ${actual.length}',
    ];
  }
  return [
    for (var i = 0; i < expected.length; i++)
      ...diffJson(expected[i], actual[i], '$path[$i]'),
  ];
}

bool _sameScalar(Object? expected, Object? actual) {
  if (_isContainer(expected) || _isContainer(actual)) return false;
  if (expected is num || actual is num) return _sameNumber(expected, actual);
  return expected == actual;
}

bool _isContainer(Object? value) => value is Map || value is List;

/// Integers and doubles never match each other, even when numerically equal.
bool _sameNumber(Object? expected, Object? actual) {
  final sameKind =
      (expected is int && actual is int) ||
      (expected is double && actual is double);
  return sameKind && expected == actual;
}

String _describe(Object? value) =>
    '${jsonEncode(value)} (${value?.runtimeType ?? 'null'})';

/// Fixture JSON text: 2-space indent, non-ASCII escaped as `\uXXXX` (UTF-16),
/// trailing newline. Used to print actual output for review, never to write.
String encodeFixtureJson(Object? value) {
  final text = const JsonEncoder.withIndent('  ').convert(value);
  final buffer = StringBuffer();
  for (final unit in text.codeUnits) {
    if (unit < 0x80) {
      buffer.writeCharCode(unit);
    } else {
      buffer.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    }
  }
  buffer.write('\n');
  return buffer.toString();
}

// ------------------------------------------------------------ JSON readers

void _checkKeys(Map<String, Object?> json, Set<String> allowed, String where) {
  final unknown = json.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw FormatException('$where: unknown keys $unknown');
  }
}

Map<String, Object?> _object(Object? raw, String where) {
  if (raw is! Map) throw FormatException('$where: expected object');
  return Map<String, Object?>.from(raw);
}

List<Object?> _list(Object? raw, String where) {
  if (raw is! List) throw FormatException('$where: expected array');
  return List<Object?>.from(raw);
}

T? _opt<T>(Map<String, Object?> json, String key, String where) {
  final value = json[key];
  if (value == null || value is T) return value as T?;
  throw FormatException('$where.$key: expected $T, got $value');
}

T _require<T>(Map<String, Object?> json, String key, String where) {
  final value = _opt<T>(json, key, where);
  if (value == null) throw FormatException('$where.$key: required');
  return value;
}

String? _optString(Map<String, Object?> json, String key, String where) =>
    _opt<String>(json, key, where);

String _requireString(Map<String, Object?> json, String key, String where) =>
    _require<String>(json, key, where);

int? _optInt(Map<String, Object?> json, String key, String where) =>
    _opt<int>(json, key, where);

int _requireInt(Map<String, Object?> json, String key, String where) =>
    _require<int>(json, key, where);

bool? _optBool(Map<String, Object?> json, String key, String where) =>
    _opt<bool>(json, key, where);

/// Accepts any JSON number; the SDK model stores a double.
double _requireDouble(Map<String, Object?> json, String key, String where) =>
    _require<num>(json, key, where).toDouble();

DateTime _epochMs(Map<String, Object?> json, String key, String where) =>
    DateTime.fromMillisecondsSinceEpoch(
      _requireInt(json, key, where),
      isUtc: true,
    );
