import 'package:http/http.dart' as http;
import 'package:tugboat/tugboat.dart';

/// Records network evidence for requests sent through [inner].
///
/// [routeResolver] maps the original URL to a bounded absolute route such as
/// `/orders/:id`. Return null to skip a request. It runs only while Tugboat
/// accepts evidence. The adapter never subscribes to request or response bodies.
///
/// Wrap a retrying client on the outside to observe one logical call.
/// Closing this client closes [inner].
class TugboatHttpClient extends http.BaseClient {
  TugboatHttpClient(http.Client inner, {required this.routeResolver})
    : _inner = inner;

  final http.Client _inner;

  /// Maps a URL to the route to include in evidence.
  final String? Function(Uri url) routeResolver;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final call = _begin(request);
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (error) {
      try {
        call?.fail(
          failure: error is http.RequestAbortedException
              ? TugboatNetworkFailure.cancelled
              : TugboatNetworkFailure.networkError,
        );
      } catch (_) {
        // Preserve the transport's original failure.
      }
      rethrow;
    }
    try {
      call?.complete(statusCode: response.statusCode);
    } catch (_) {
      // Evidence failures must never prevent delivery of a response.
    }
    return response;
  }

  TugboatNetworkCall? _begin(http.BaseRequest request) {
    try {
      if (!TugboatReplay.isAcceptingEvidence) return null;
      final controller = TugboatReplay.controller;
      final session = controller?.session;
      final route = routeResolver(request.url);
      if (session == null ||
          !identical(controller, TugboatReplay.controller) ||
          !identical(session, controller?.session)) {
        return null;
      }
      return TugboatReplay.beginNetworkCall(
        method: request.method,
        route: route,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void close() => _inner.close();
}
