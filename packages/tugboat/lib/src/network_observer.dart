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
    required TugboatNetworkOutcome outcome,
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
    required TugboatNetworkOutcome outcome,
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
  if (trimmed.length > TugboatNetworkLimits.maxRouteLength) return null;
  return trimmed;
}
