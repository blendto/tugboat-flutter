import 'dart:convert';
import 'dart:typed_data';

/// Closed vocabulary for a logical network call's terminal outcome.
enum TugboatNetworkOutcome {
  response,
  networkError,
  cancelled;

  String get wireName => switch (this) {
    TugboatNetworkOutcome.response => 'response',
    TugboatNetworkOutcome.networkError => 'network_error',
    TugboatNetworkOutcome.cancelled => 'cancelled',
  };
}

/// Failure reasons accepted by [TugboatNetworkCall.fail].
enum TugboatNetworkFailure {
  networkError,
  cancelled;

  TugboatNetworkOutcome get outcome => switch (this) {
    TugboatNetworkFailure.networkError => TugboatNetworkOutcome.networkError,
    TugboatNetworkFailure.cancelled => TugboatNetworkOutcome.cancelled,
  };
}

/// Hard limits for host-supplied network observation fields.
abstract final class TugboatNetworkLimits {
  static const maxMethodLength = 16;
  static const maxRouteLength = 256;
  static const maxErrorResponseBodyBytes = 16 * 1024;
  static const maxErrorResponseBodyDepth = 6;
  static const maxErrorResponseBodyCollectionItems = 128;
}

/// Bounded snapshot of an HTTP error response body.
class TugboatNetworkErrorBodySnapshot {
  const TugboatNetworkErrorBodySnapshot({
    required this.value,
    required this.format,
    required this.truncated,
    this.representation = 'native',
  });

  final Object? value;
  final String format;
  final bool truncated;
  final String representation;

  Map<String, Object?> toCaptureMetadata() => {
    'format': format,
    'representation': representation,
    'truncated': truncated,
  };
}

/// Exactly-once observation token for one logical HTTP request.
///
/// Adapters call [complete] or [fail] when response headers/status are
/// available. Further terminal calls are no-ops.
abstract interface class TugboatNetworkCall {
  void complete({
    int? statusCode,
    int? attemptCount,
    Object? errorResponseBody,
  });

  void fail({
    required TugboatNetworkFailure failure,
    int? statusCode,
    int? attemptCount,
    Object? errorResponseBody,
  });
}

/// No-op token used when Tugboat is dormant, disabled, or the route is empty.
class TugboatNoOpNetworkCall implements TugboatNetworkCall {
  const TugboatNoOpNetworkCall();

  @override
  void complete({
    int? statusCode,
    int? attemptCount,
    Object? errorResponseBody,
  }) {}

  @override
  void fail({
    required TugboatNetworkFailure failure,
    int? statusCode,
    int? attemptCount,
    Object? errorResponseBody,
  }) {}
}

/// Returns a deep-copied, bounded JSON/text body for HTTP error responses.
///
/// Binary and unsupported bodies are deliberately omitted. Oversized JSON is
/// retained as a bounded serialized prefix with explicit capture metadata.
TugboatNetworkErrorBodySnapshot? snapshotNetworkErrorResponseBody(Object? raw) {
  if (raw == null ||
      raw is ByteBuffer ||
      raw is TypedData ||
      raw is List<int>) {
    return null;
  }

  if (raw is String) {
    final bounded = _boundedUtf8Prefix(
      raw,
      TugboatNetworkLimits.maxErrorResponseBodyBytes,
    );
    return TugboatNetworkErrorBodySnapshot(
      value: bounded.value,
      format: 'text',
      truncated: bounded.truncated,
    );
  }

  final normalized = _copyJsonValue(raw, depth: 0);
  if (!normalized.supported) return null;
  final encoded = jsonEncode(normalized.value);
  final encodedBytes = utf8.encode(encoded);
  if (encodedBytes.length <= TugboatNetworkLimits.maxErrorResponseBodyBytes) {
    return TugboatNetworkErrorBodySnapshot(
      value: normalized.value,
      format: 'json',
      truncated: normalized.truncated,
    );
  }

  final bounded = _boundedUtf8Prefix(
    encoded,
    TugboatNetworkLimits.maxErrorResponseBodyBytes,
  );
  return TugboatNetworkErrorBodySnapshot(
    value: bounded.value,
    format: 'json',
    representation: 'serialized_prefix',
    truncated: true,
  );
}

({String value, bool truncated}) _boundedUtf8Prefix(
  String value,
  int maxBytes,
) {
  if (utf8.encode(value).length <= maxBytes) {
    return (value: value, truncated: false);
  }
  final buffer = StringBuffer();
  var usedBytes = 0;
  for (final rune in value.runes) {
    final runeValue = String.fromCharCode(rune);
    final runeBytes = utf8.encode(runeValue).length;
    if (usedBytes + runeBytes > maxBytes) break;
    buffer.write(runeValue);
    usedBytes += runeBytes;
  }
  return (value: buffer.toString(), truncated: true);
}

({Object? value, bool supported, bool truncated}) _copyJsonValue(
  Object? value, {
  required int depth,
}) {
  if (value == null || value is bool || value is String) {
    return (value: value, supported: true, truncated: false);
  }
  if (value is num) {
    if (value is double && !value.isFinite) {
      return (value: null, supported: false, truncated: true);
    }
    return (value: value, supported: true, truncated: false);
  }
  if (depth >= TugboatNetworkLimits.maxErrorResponseBodyDepth) {
    return (value: null, supported: false, truncated: true);
  }
  if (value is List) {
    final copied = <Object?>[];
    var truncated =
        value.length > TugboatNetworkLimits.maxErrorResponseBodyCollectionItems;
    for (final item in value.take(
      TugboatNetworkLimits.maxErrorResponseBodyCollectionItems,
    )) {
      final normalized = _copyJsonValue(item, depth: depth + 1);
      if (!normalized.supported) {
        truncated = true;
        continue;
      }
      copied.add(normalized.value);
      truncated = truncated || normalized.truncated;
    }
    return (value: copied, supported: true, truncated: truncated);
  }
  if (value is Map) {
    final copied = <String, Object?>{};
    var truncated =
        value.length > TugboatNetworkLimits.maxErrorResponseBodyCollectionItems;
    var visited = 0;
    for (final entry in value.entries) {
      if (visited >= TugboatNetworkLimits.maxErrorResponseBodyCollectionItems) {
        truncated = true;
        break;
      }
      visited += 1;
      if (entry.key is! String) {
        truncated = true;
        continue;
      }
      final normalized = _copyJsonValue(entry.value, depth: depth + 1);
      if (!normalized.supported) {
        truncated = true;
        continue;
      }
      copied[entry.key as String] = normalized.value;
      truncated = truncated || normalized.truncated;
    }
    return (value: copied, supported: true, truncated: truncated);
  }
  return (value: null, supported: false, truncated: true);
}

String? normalizeNetworkMethod(String method) {
  final trimmed = method.trim().toUpperCase();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > TugboatNetworkLimits.maxMethodLength) return null;
  return trimmed;
}

String? normalizeNetworkRoute(String? route) {
  if (route == null) return null;
  final trimmed = route.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed != route) return null;
  if (trimmed.length > TugboatNetworkLimits.maxRouteLength) return null;
  // Routes are host-supplied bounded paths, never arbitrary URLs. Requiring an
  // absolute path and rejecting URI delimiters, encoded delimiters, backslash,
  // and whitespace keeps complete request URLs out of evidence. Dynamic
  // identifier segments are allowed.
  if (!trimmed.startsWith('/') || trimmed.startsWith('//')) return null;
  if (trimmed.contains('://')) return null;
  if (trimmed.runes.any(_isForbiddenRouteRune)) return null;
  return trimmed;
}

bool _isForbiddenRouteRune(int rune) {
  if (rune <= 0x20 || rune == 0x7f) return true;
  return rune == '%'.codeUnitAt(0) ||
      rune == '#'.codeUnitAt(0) ||
      rune == '?'.codeUnitAt(0) ||
      rune == r'\'.codeUnitAt(0);
}
