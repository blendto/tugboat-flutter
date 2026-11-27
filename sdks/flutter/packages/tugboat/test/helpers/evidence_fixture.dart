// Evaluates `evidence.externalEvent` and `evidence.networkCall` fixtures
// against the shipped Dart `TugboatEvidenceRecorder` (see
// `conformance/README.md` and `core/session-engine/docs/
// evidence-messages.md`). The fixture input is the engine message input:
// its typed value encoding is mapped onto the Dart objects a host would
// hand the recorder, so Dart's own snapshot and normalize functions decide
// the expected `data`.
import 'dart:collection';
import 'dart:convert';

import 'package:tugboat/src/evidence_recorder.dart';
import 'package:tugboat/src/external_event.dart';
import 'package:tugboat/src/models.dart';
import 'package:tugboat/src/network_observer.dart';

/// The `recordExternalEvent` arguments an `evidence.externalEvent` input
/// stands for.
typedef ExternalEventArguments = ({
  String name,
  String? source,
  Map<String, Object?>? parameters,
  TugboatParameterPolicy policy,
});

ExternalEventArguments externalEventArguments(Map<String, Object?> input) {
  _checkKeys(input, const {
    'name',
    'source',
    'policy',
    'parameters',
    'atMonoUs',
  });
  final policyJson = input['policy']! as Map<String, Object?>;
  final decoded = _decodeParameters(input['parameters']);
  return (
    name: input['name']! as String,
    source: input['source'] as String?,
    parameters: decoded?.raw,
    policy: _policy(policyJson['mode']! as String, policyJson, decoded),
  );
}

/// `{data}`: the recorded event's data, or `null` when nothing is recorded.
Map<String, Object?> evaluateExternalEventFixture(Map<String, Object?> input) {
  final arguments = externalEventArguments(input);
  final harness = _RecorderHarness();
  harness.recorder.recordExternalEvent(
    name: arguments.name,
    source: arguments.source,
    parameters: arguments.parameters,
    parameterPolicy: arguments.policy,
  );
  return {'data': harness.data};
}

/// `{data}` for a network call begun at `startMonoUs` and finished at
/// `endMonoUs` (default the start) in a session that started at monoUs 0.
Map<String, Object?> evaluateNetworkCallFixture(Map<String, Object?> input) {
  _checkKeys(input, const {
    'method',
    'route',
    'startMonoUs',
    'endMonoUs',
    'statusCode',
    'outcome',
    'attemptCount',
    'errorResponseBody',
  });
  final start = input['startMonoUs']! as int;
  final end = input['endMonoUs'] as int? ?? start;
  final harness = _RecorderHarness()..nowMs = start ~/ 1000;
  final call = harness.recorder.beginNetworkCall(
    method: input['method']! as String,
    route: input['route']! as String,
  );
  harness.nowMs = end ~/ 1000;
  final statusCode = input['statusCode'] as int?;
  final attemptCount = input['attemptCount'] as int?;
  final body = _decodeErrorBody(input['errorResponseBody']);
  final outcome = input['outcome']! as String;
  if (outcome == 'response') {
    call.complete(
      statusCode: statusCode,
      attemptCount: attemptCount,
      errorResponseBody: body,
    );
  } else {
    call.fail(
      failure: outcome == 'cancelled'
          ? TugboatNetworkFailure.cancelled
          : TugboatNetworkFailure.networkError,
      statusCode: statusCode,
      attemptCount: attemptCount,
      errorResponseBody: body,
    );
  }
  return {'data': harness.data};
}

class _RecorderHarness {
  _RecorderHarness() {
    recorder = TugboatEvidenceRecorder(
      appendEvidence: events.add,
      nextEventId: (prefix) => '$prefix-0',
      nowMs: () => nowMs,
    );
    recorder.bindSession(
      TugboatSession(
        id: 'session-1781827200000000',
        startedAt: DateTime.utc(2026, 6, 19),
        platform: 'android',
        viewport: const TugboatRect(0, 0, 412, 915),
      ),
    );
  }

  late final TugboatEvidenceRecorder recorder;
  final events = <TugboatEvent>[];
  int nowMs = 0;

  Map<String, Object?>? get data {
    if (events.length > 1) throw StateError('more than one event recorded');
    return events.isEmpty ? null : events.single.data;
  }
}

TugboatParameterPolicy _policy(
  String mode,
  Map<String, Object?> json,
  _DecodedParameters? decoded,
) {
  switch (mode) {
    case 'names_only':
      return TugboatParameterPolicy.namesOnly;
    case 'allow_list':
      final keys = (json['allowedKeys']! as List).cast<String>();
      return TugboatParameterPolicy.allowList(keys.toSet());
    case 'transform':
      final results = decoded?.values ?? const <String, Object?>{};
      return TugboatParameterPolicy.transform((key, _) => results[key]);
    case 'allow_all':
      return TugboatParameterPolicy.allowAll;
  }
  throw FormatException('unknown policy mode $mode');
}

/// The parameters map a host would pass, plus each key's decoded value, which
/// a `transform` closure returns (the fixture carries transform results).
class _DecodedParameters {
  final raw = <String, Object?>{};
  final values = <String, Object?>{};
}

_DecodedParameters? _decodeParameters(Object? json) {
  if (json == null) return null;
  final tag = json as Map<String, Object?>;
  final out = _DecodedParameters();
  var invalid = 0;
  for (final entry in tag['map']! as List) {
    if (entry is Map) {
      for (var i = 0; i < (entry['nonStringKeys']! as int); i++) {
        // An invalid top-level key: longer than 128 UTF-16 units.
        out.raw['${'k' * 129}${invalid++}'] = null;
      }
      continue;
    }
    final pair = entry as List;
    final key = pair[0] as String;
    final value = _ValueDecoder().decode(pair[1]);
    out.raw[key] = value;
    out.values[key] = value;
  }
  for (var i = 0; i < (tag['omitted'] as int? ?? 0); i++) {
    out.raw['\u0000omitted$i'] = null;
  }
  return out;
}

Object? _decodeErrorBody(Object? json) {
  if (json == null) return null;
  final body = json as Map<String, Object?>;
  if (body.containsKey('value')) return _ValueDecoder().decode(body['value']);
  final text = body['jsonText']! as String;
  if (text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return text;
  }
}

/// A Dart `Iterable` that is not a `List` (the `iterable` tag).
class _FixtureIterable extends IterableBase<Object?> {
  _FixtureIterable(this.items);

  final List<Object?> items;

  @override
  Iterator<Object?> get iterator => items.iterator;
}

/// Maps the typed value encoding onto Dart objects. `ref` resolves to the
/// real enclosing collection, so cycles are real cycles.
class _ValueDecoder {
  final _ancestors = <Object>[];

  Object? decode(Object? json) {
    if (json is double) {
      throw const FormatException('a bare number must be an integer');
    }
    if (json is List) return _collection(<Object?>[], json, 0);
    if (json is Map<String, Object?>) return _tag(json);
    return json;
  }

  Object? _tag(Map<String, Object?> tag) {
    final omitted = tag['omitted'] as int? ?? 0;
    if (tag.containsKey('list')) {
      return _collection(<Object?>[], tag['list']! as List, omitted);
    }
    if (tag.containsKey('iterable')) {
      final iterable = _FixtureIterable(<Object?>[]);
      return _collection(iterable, tag['iterable']! as List, omitted);
    }
    if (tag.containsKey('map')) return _map(tag['map']! as List, omitted);
    if (tag.containsKey('double')) return _double(tag['double']);
    if (tag.containsKey('ref')) {
      return _ancestors[_ancestors.length - (tag['ref']! as int)];
    }
    if (tag.containsKey('drop')) return TugboatParameterPolicy.drop;
    return Object(); // unsupported
  }

  Object _collection(Object target, List json, int omitted) {
    final items = target is _FixtureIterable
        ? target.items
        : target as List<Object?>;
    _ancestors.add(target);
    for (final item in json) {
      items.add(decode(item));
    }
    for (var i = 0; i < omitted; i++) {
      items.add(Object());
    }
    _ancestors.removeLast();
    return target;
  }

  Map<Object?, Object?> _map(List entries, int omitted) {
    final out = <Object?, Object?>{};
    _ancestors.add(out);
    for (final entry in entries) {
      if (entry is Map) {
        for (var i = 0; i < (entry['nonStringKeys']! as int); i++) {
          // A fresh `Object()` is a distinct key that is not a `String`.
          out[Object()] = null;
        }
        continue;
      }
      final pair = entry as List;
      out[pair[0] as String] = decode(pair[1]);
    }
    for (var i = 0; i < omitted; i++) {
      out['\u0000omitted$i'] = Object();
    }
    _ancestors.removeLast();
    return out;
  }

  double _double(Object? json) => switch (json) {
    'NaN' => double.nan,
    'Infinity' => double.infinity,
    '-Infinity' => double.negativeInfinity,
    '-0.0' => -0.0,
    final num value => value.toDouble(),
    _ => throw FormatException('bad double tag $json'),
  };
}

void _checkKeys(Map<String, Object?> json, Set<String> allowed) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('unknown input key $key');
    }
  }
}
