import 'dart:convert';

import 'capture_profile.dart';

/// Closed vocabulary for how external-event parameter values were retained.
enum TugboatParameterCaptureMode {
  namesOnly,
  allowList,
  transform,
  allowAll;

  String get wireName => switch (this) {
    TugboatParameterCaptureMode.namesOnly => 'names_only',
    TugboatParameterCaptureMode.allowList => 'allow_list',
    TugboatParameterCaptureMode.transform => 'transform',
    TugboatParameterCaptureMode.allowAll => 'allow_all',
  };
}

/// Sentinel returned from a [TugboatParameterPolicy.transform] callback to omit
/// a parameter value without treating `null` as a drop.
class TugboatParameterDrop {
  const TugboatParameterDrop._();
}

/// Policy controlling which external-event parameter values are retained.
///
/// Parameter keys may be captured by default. Values are captured only through
/// an explicit allow-list, transform, or the deliberately named [allowAll]
/// exploration escape hatch.
class TugboatParameterPolicy {
  const TugboatParameterPolicy._({
    required this.mode,
    this.allowedKeys,
    this.valueTransform,
  });

  /// Record event name plus bounded parameter keys only. Default production
  /// policy.
  static const namesOnly = TugboatParameterPolicy._(
    mode: TugboatParameterCaptureMode.namesOnly,
  );

  /// Preserve JSON-safe values only for the named keys.
  static TugboatParameterPolicy allowList(Set<String> keys) =>
      TugboatParameterPolicy._(
        mode: TugboatParameterCaptureMode.allowList,
        allowedKeys: Set<String>.unmodifiable(keys),
      );

  /// Host callback returns the retained JSON-safe value, or [drop] to omit it.
  /// Callback failures are caught and treated as drops.
  static TugboatParameterPolicy transform(
    Object? Function(String key, Object? value) transform,
  ) => TugboatParameterPolicy._(
    mode: TugboatParameterCaptureMode.transform,
    valueTransform: transform,
  );

  /// Exploration-only escape hatch that retains all JSON-safe values within
  /// hard limits. Can capture feedback text, search terms, IDs, and other user
  /// content. Do not use as the default production example.
  ///
  /// Outside [TugboatCaptureProfile.exploration], [effectiveFor] downgrades
  /// this to [namesOnly].
  static const allowAll = TugboatParameterPolicy._(
    mode: TugboatParameterCaptureMode.allowAll,
  );

  /// Sentinel for transform callbacks.
  static const drop = TugboatParameterDrop._();

  final TugboatParameterCaptureMode mode;
  final Set<String>? allowedKeys;
  final Object? Function(String key, Object? value)? valueTransform;

  /// Wire label for capture metadata (`names_only`, `allow_list`, …).
  String get captureValues => mode.wireName;

  /// Resolves exploration-only escape hatches against the active profile.
  TugboatParameterPolicy effectiveFor(TugboatCaptureProfile profile) {
    if (mode == TugboatParameterCaptureMode.allowAll &&
        profile != TugboatCaptureProfile.exploration) {
      return namesOnly;
    }
    return this;
  }
}

/// Hard limits applied when snapshotting external-event parameters.
abstract final class TugboatParameterLimits {
  static const maxDepth = 4;
  static const maxTopLevelKeys = 64;
  static const maxCollectionItems = 256;
  static const maxKeyLength = 128;
  static const maxStringLength = 1024;
  static const maxEncodedBytes = 16 * 1024;
  static const maxNameLength = 256;
  static const maxSourceLength = 128;
}

/// Result of applying a [TugboatParameterPolicy] to a host parameter map.
class TugboatParameterSnapshot {
  const TugboatParameterSnapshot({
    required this.parameterKeys,
    required this.parameters,
    required this.captureValues,
    required this.truncated,
    required this.droppedCount,
  });

  final List<String> parameterKeys;
  final Map<String, Object?>? parameters;
  final String captureValues;
  final bool truncated;
  final int droppedCount;

  Map<String, Object?> toCaptureMetadata() => {
    'values': captureValues,
    'truncated': truncated,
    'droppedCount': droppedCount,
  };
}

/// Snapshots and bounds host parameters into JSON-safe retained values.
TugboatParameterSnapshot snapshotExternalParameters({
  required TugboatParameterPolicy policy,
  Map<String, Object?>? parameters,
}) {
  final raw = parameters;
  if (raw == null || raw.isEmpty) {
    return TugboatParameterSnapshot(
      parameterKeys: const [],
      parameters: null,
      captureValues: policy.captureValues,
      truncated: false,
      droppedCount: 0,
    );
  }

  var dropped = 0;
  var truncated = false;
  var collectionItems = 0;
  final keys = <String>[];
  final retained = <String, Object?>{};

  final entries = raw.entries.take(TugboatParameterLimits.maxTopLevelKeys);
  if (raw.length > TugboatParameterLimits.maxTopLevelKeys) {
    truncated = true;
    dropped += raw.length - TugboatParameterLimits.maxTopLevelKeys;
  }

  for (final entry in entries) {
    final key = entry.key;
    if (key.isEmpty || key.length > TugboatParameterLimits.maxKeyLength) {
      dropped += 1;
      truncated = true;
      continue;
    }
    keys.add(key);

    final candidate = switch (policy.mode) {
      TugboatParameterCaptureMode.namesOnly => _skipValue,
      TugboatParameterCaptureMode.allowList =>
        (policy.allowedKeys?.contains(key) ?? false) ? entry.value : _dropValue,
      TugboatParameterCaptureMode.transform => _applyTransform(
        policy,
        key,
        entry.value,
      ),
      TugboatParameterCaptureMode.allowAll => entry.value,
    };
    if (identical(candidate, _skipValue)) continue;
    if (identical(candidate, _dropValue)) {
      dropped += 1;
      continue;
    }

    final copied = _copyJsonSafe(
      candidate,
      depth: 1,
      seen: <Object>{},
      dropped: (count) {
        dropped += count;
        truncated = true;
      },
      onCollectionItem: () {
        collectionItems += 1;
        if (collectionItems > TugboatParameterLimits.maxCollectionItems) {
          truncated = true;
          return false;
        }
        return true;
      },
    );
    if (identical(copied, _unsupported)) continue;
    retained[key] = copied;
  }

  Map<String, Object?>? parametersOut;
  if (policy.mode != TugboatParameterCaptureMode.namesOnly &&
      retained.isNotEmpty) {
    parametersOut = Map<String, Object?>.unmodifiable(retained);
    final encodedLength = utf8.encode(jsonEncode(parametersOut)).length;
    if (encodedLength > TugboatParameterLimits.maxEncodedBytes) {
      // Drop values entirely when the bounded payload still exceeds the budget.
      // Keys remain so the event stays observable without retaining oversize
      // content.
      truncated = true;
      dropped += retained.length;
      parametersOut = null;
    }
  }

  return TugboatParameterSnapshot(
    parameterKeys: List<String>.unmodifiable(keys),
    parameters: parametersOut,
    captureValues: policy.captureValues,
    truncated: truncated,
    droppedCount: dropped,
  );
}

const _Sentinel _unsupported = _Sentinel('unsupported');
const _Sentinel _skipValue = _Sentinel('skip');
const _Sentinel _dropValue = _Sentinel('drop');

class _Sentinel {
  const _Sentinel(this.label);
  final String label;
}

Object? _applyTransform(
  TugboatParameterPolicy policy,
  String key,
  Object? value,
) {
  final transform = policy.valueTransform;
  if (transform == null) return _dropValue;
  try {
    final candidate = transform(key, value);
    if (identical(candidate, TugboatParameterPolicy.drop)) return _dropValue;
    return candidate;
  } catch (_) {
    return _dropValue;
  }
}

Object? _copyJsonSafe(
  Object? value, {
  required int depth,
  required Set<Object> seen,
  required void Function(int count) dropped,
  required bool Function() onCollectionItem,
}) {
  if (depth > TugboatParameterLimits.maxDepth) {
    dropped(1);
    return _unsupported;
  }
  if (value == null || value is bool) return value;
  if (value is num) {
    if (value.isFinite) return value;
    dropped(1);
    return _unsupported;
  }
  if (value is String) {
    if (value.length <= TugboatParameterLimits.maxStringLength) return value;
    dropped(1);
    return _unsupported;
  }
  if (value is Map) {
    if (!seen.add(value)) {
      dropped(1);
      return _unsupported;
    }
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String ||
          key.isEmpty ||
          key.length > TugboatParameterLimits.maxKeyLength) {
        dropped(1);
        continue;
      }
      if (!onCollectionItem()) {
        dropped(1);
        break;
      }
      final copied = _copyJsonSafe(
        entry.value,
        depth: depth + 1,
        seen: seen,
        dropped: dropped,
        onCollectionItem: onCollectionItem,
      );
      if (identical(copied, _unsupported)) continue;
      out[key] = copied;
    }
    seen.remove(value);
    return out;
  }
  if (value is Iterable) {
    if (!seen.add(value)) {
      dropped(1);
      return _unsupported;
    }
    final out = <Object?>[];
    for (final item in value) {
      if (!onCollectionItem()) {
        dropped(1);
        break;
      }
      final copied = _copyJsonSafe(
        item,
        depth: depth + 1,
        seen: seen,
        dropped: dropped,
        onCollectionItem: onCollectionItem,
      );
      if (identical(copied, _unsupported)) continue;
      out.add(copied);
    }
    seen.remove(value);
    return out;
  }
  dropped(1);
  return _unsupported;
}

/// Host-facing callable for recording one logical app/analytics event.
abstract interface class TugboatEventHook {
  void record(String name, {Map<String, Object?>? parameters});
}

String? boundExternalLabel(String? value, int maxLength) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > maxLength) return trimmed.substring(0, maxLength);
  return trimmed;
}
