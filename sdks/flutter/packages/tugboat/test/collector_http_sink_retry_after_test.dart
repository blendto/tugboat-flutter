import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_http_sink.dart';
import 'package:tugboat/src/models.dart';

void main() {
  test('events lane waits after 429 Retry-After before retrying', () async {
    var now = DateTime.utc(2026, 1, 1);
    var batchAttempts = 0;
    final client = _SequenceClient(
      onBatch: () {
        batchAttempts++;
        if (batchAttempts == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('{}')),
            429,
            headers: const {'retry-after': '1'},
          );
        }
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 202);
      },
    );
    final config = TugboatCollectorConfig(
      baseUrl: 'http://example.invalid',
      apiKey: 'pmk_test',
      appInfo: const TugboatCollectorAppInfo(
        name: 'App',
        version: '1',
        buildNumber: '1',
        installationId: 'i',
        appId: 'com.example',
      ),
      deviceInfo: const TugboatCollectorDeviceInfo(
        id: 'd',
        platform: 'ios',
        screenSize: TugboatCollectorScreenSize(width: 100, height: 100),
        screenDensity: 1,
        screenDpi: 160,
        screenPixelDensity: 1,
      ),
      ipInfo: const TugboatCollectorIpInfo(ip: '127.0.0.1'),
      locale: const TugboatCollectorLocaleInfo(language: 'en'),
    );
    final sink = CollectorHttpSink(
      config: config,
      client: client,
      debugNow: () => now,
    );
    sink.startSession(
      TugboatSession(
        id: 's1',
        startedAt: now,
        viewport: const TugboatRect(0, 0, 100, 100),
        platform: 'test',
      ),
    );
    sink.recordEvent(
      const TugboatEvent(
        id: 'e1',
        atMs: 0,
        type: 'interaction',
        stream: TugboatEventStream.semantic,
        data: {'interactionSchema': 2, 'gesture': 'tap'},
      ),
    );
    await sink.flush();
    expect(batchAttempts, 1);
    now = now.add(const Duration(milliseconds: 1100));
    await sink.flush();
    expect(batchAttempts, 2);
  });
}

class _SequenceClient extends http.BaseClient {
  _SequenceClient({required this.onBatch});

  final http.StreamedResponse Function() onBatch;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/v1/sessions') {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"sessionId":"srv"}')),
        202,
      );
    }
    return onBatch();
  }
}
