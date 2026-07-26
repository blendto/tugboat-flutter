import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/outbox/outbox.dart';

void main() {
  test(
    'recovery test reloads only unacked envelopes after process restart',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'tugboat_outbox_recover_',
      );
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });

      final config = TugboatOutboxConfig(enabled: true, directory: dir);
      final writer = TugboatOutboxStore(config: config);
      await writer.append(
        TugboatOutboxEnvelope(
          idempotencyKey: 'pending-1',
          kind: 'event',
          captureSessionId: 'cap-1',
          payloadJson: {
            'id': 'e1',
            'type': 'tap',
            'atMs': 1,
            // Ensure no free-text label leaks into durable payload contract tests.
          },
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await writer.append(
        TugboatOutboxEnvelope(
          idempotencyKey: 'done-1',
          kind: 'event',
          captureSessionId: 'cap-1',
          payloadJson: {'id': 'e2', 'type': 'route_change', 'atMs': 2},
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await writer.acknowledge('done-1');

      // Simulate process death: new store instance, same directory.
      final recovered = TugboatOutboxStore(config: config);
      await recovered.load();
      expect(recovered.pending().map((e) => e.idempotencyKey), ['pending-1']);
      for (final entry in recovered.pending()) {
        final encoded = entry.toJson().toString();
        expect(encoded.contains('password'), isFalse);
        expect(encoded.contains('Bearer'), isFalse);
      }
    },
  );
}
