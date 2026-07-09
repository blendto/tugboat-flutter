import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/exploration_transport.dart';
import 'package:tugboat/src/models.dart';

void main() {
  test(
    'notifies when the exploration collector connects and disconnects',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

      final connected = Completer<void>();
      final disconnected = Completer<void>();
      final transport = TugboatExplorationTransport(
        url: 'ws://127.0.0.1:${server.port}/sdk',
        runId: 'run-1',
        onControl: (_) {},
        onConnected: connected.complete,
        onDisconnected: disconnected.complete,
      );

      server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((_) {});
      });

      await transport.connect();
      await connected.future.timeout(const Duration(seconds: 2));

      transport.dispose();
      await disconnected.future.timeout(const Duration(seconds: 2));
    },
  );

  test('buffers session and event messages until connected', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    final messages = <String>[];
    final transport = TugboatExplorationTransport(
      url: 'ws://127.0.0.1:${server.port}/sdk',
      runId: 'run-1',
      onControl: (_) {},
    );

    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) => messages.add(raw as String));
    });

    transport.sendEvent(TugboatEvent(id: 'event-1', atMs: 1, type: 'tap'));
    await transport.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(messages, isNotEmpty);
    final decoded = jsonDecode(messages.first) as Map<String, dynamic>;
    expect(decoded['type'], 'event');
    expect((decoded['payload'] as Map)['type'], 'tap');

    transport.dispose();
  });
}
