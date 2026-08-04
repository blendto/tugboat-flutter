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
}

/// Exactly-once observation token for one logical HTTP request.
///
/// Adapters call [complete] or [fail] when response headers/status are
/// available. Further terminal calls are no-ops.
abstract interface class TugboatNetworkCall {
  void complete({int? statusCode, int? attemptCount});

  void fail({
    required TugboatNetworkFailure failure,
    int? statusCode,
    int? attemptCount,
  });
}

/// No-op token used when Tugboat is dormant, disabled, or the route is empty.
class TugboatNoOpNetworkCall implements TugboatNetworkCall {
  const TugboatNoOpNetworkCall();

  @override
  void complete({int? statusCode, int? attemptCount}) {}

  @override
  void fail({
    required TugboatNetworkFailure failure,
    int? statusCode,
    int? attemptCount,
  }) {}
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
  // Routes are host-supplied templates, never arbitrary URLs. Requiring an
  // absolute path and rejecting URI delimiters, encoded delimiters, backslash,
  // and whitespace keeps accidental raw request URLs out of evidence. Dynamic
  // IDs still need to be removed by the host's route resolver.
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
