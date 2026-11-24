import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tugboat/tugboat.dart';
import 'package:tugboat_http/tugboat_http.dart';

class _Transport extends http.BaseClient {
  _Transport(this.handle);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handle(request);

  @override
  void close() => closed = true;
}

void main() {
  final url = Uri.parse('https://example.test/users/secret?token=private');
  tearDown(TugboatReplay.resetForTest);

  test('dormant client skips route resolution and forwards close', () async {
    var resolutions = 0;
    final inner = _Transport(
      (_) async => http.StreamedResponse(const Stream.empty(), 204),
    );
    final client = TugboatHttpClient(
      inner,
      routeResolver: (_) {
        resolutions++;
        return '/users/:id';
      },
    );
    expect((await client.get(url)).statusCode, 204);
    expect(resolutions, 0);
    client.close();
    expect(inner.closed, isTrue);
  });

  testWidgets('observes headers and send failures without consuming streams', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(enabled: true),
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();
    try {
      final request = http.Request('POST', url);
      final body = StreamController<List<int>>();
      final response = http.StreamedResponse(body.stream, 503);
      final inner = _Transport((actual) async {
        expect(actual, same(request));
        return response;
      });
      final client = TugboatHttpClient(
        inner,
        routeResolver: (_) => '/users/:id',
      );
      expect(await client.send(request), same(response));
      expect(body.hasListener, isFalse);
      final events = TugboatReplay.controller!.session!.events.where(
        (event) => event.type == 'network_call',
      );
      final data = events.single.data;
      expect(data['method'], 'POST');
      expect(data['statusCode'], 503);
      expect(data['route'], '/users/:id');
      expect(data['outcome'], 'response');
      expect(data.containsKey('errorResponseBody'), isFalse);
      expect(data.toString(), isNot(contains('secret')));
      expect(data.toString(), isNot(contains('private')));
      final drain = response.stream.drain<void>();
      await body.close();
      await drain;

      for (final (error, outcome) in [
        (http.ClientException('private'), 'network_error'),
        (http.RequestAbortedException(url), 'cancelled'),
      ]) {
        final failing = TugboatHttpClient(
          _Transport((_) async => throw error),
          routeResolver: (_) => '/users/:id',
        );
        await expectLater(failing.get(url), throwsA(same(error)));
        expect(events.last.data['outcome'], outcome);
        expect(events.last.data.toString(), isNot(contains('private')));
      }
      for (final resolver in <String? Function(Uri)>[
        (_) => null,
        (_) => '/bad?query',
        (_) => throw StateError('resolver failed'),
      ]) {
        expect(
          await TugboatHttpClient(inner, routeResolver: resolver).send(request),
          same(response),
        );
      }
      expect(events, hasLength(3));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      TugboatReplay.resetForTest();
      await tester.pump(const Duration(seconds: 10));
    }
  });
}
