import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/outbox/outbox.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tugboat_outbox_test_');
  });

  tearDown(() async {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  test('append and acknowledge round trip', () async {
    final store = TugboatOutboxStore(
      config: TugboatOutboxConfig(enabled: true, directory: dir),
    );
    await store.append(
      TugboatOutboxEnvelope(
        idempotencyKey: 'k1',
        kind: 'event',
        captureSessionId: 'cap-1',
        activationRequestId: 'req-1',
        payloadJson: {'id': 'e1', 'type': 'tap', 'atMs': 1},
        createdAt: DateTime.now().toUtc(),
      ),
    );
    expect(store.pending(), hasLength(1));
    await store.acknowledge('k1');
    expect(store.pending(), isEmpty);

    // Duplicate ack is harmless.
    await store.acknowledge('k1');
    expect(store.pending(), isEmpty);
  });

  test('restart recovers unacknowledged entries', () async {
    final config = TugboatOutboxConfig(enabled: true, directory: dir);
    final first = TugboatOutboxStore(config: config);
    await first.append(
      TugboatOutboxEnvelope(
        idempotencyKey: 'k-keep',
        kind: 'event',
        captureSessionId: 'cap-1',
        payloadJson: {'id': 'e1', 'type': 'tap'},
        createdAt: DateTime.now().toUtc(),
      ),
    );
    await first.append(
      TugboatOutboxEnvelope(
        idempotencyKey: 'k-ack',
        kind: 'event',
        captureSessionId: 'cap-1',
        payloadJson: {'id': 'e2', 'type': 'tap'},
        createdAt: DateTime.now().toUtc(),
      ),
    );
    await first.acknowledge('k-ack');

    final second = TugboatOutboxStore(config: config);
    await second.load();
    final pending = second.pending();
    expect(pending, hasLength(1));
    expect(pending.single.idempotencyKey, 'k-keep');
  });

  test('corrupted line is quarantined without blocking', () async {
    final file = File('${dir.path}/outbox.jsonl');
    await file.writeAsString('not-json\n');
    final store = TugboatOutboxStore(
      config: TugboatOutboxConfig(enabled: true, directory: dir),
    );
    await store.load();
    expect(store.quarantineReasons, contains('corrupt_line'));
    await store.append(
      TugboatOutboxEnvelope(
        idempotencyKey: 'k2',
        kind: 'event',
        captureSessionId: 'cap-1',
        payloadJson: {'id': 'e3', 'type': 'tap'},
        createdAt: DateTime.now().toUtc(),
      ),
    );
    expect(store.pending(), hasLength(1));
  });

  test('entry bounds are enforced', () async {
    final store = TugboatOutboxStore(
      config: TugboatOutboxConfig(enabled: true, directory: dir, maxEntries: 2),
    );
    for (var i = 0; i < 4; i++) {
      await store.append(
        TugboatOutboxEnvelope(
          idempotencyKey: 'k$i',
          kind: 'event',
          captureSessionId: 'cap-1',
          payloadJson: {'id': 'e$i', 'type': 'tap'},
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }
    expect(store.pending().length, lessThanOrEqualTo(2));
  });

  test('clear wipes durable state', () async {
    final store = TugboatOutboxStore(
      config: TugboatOutboxConfig(enabled: true, directory: dir),
    );
    await store.append(
      TugboatOutboxEnvelope(
        idempotencyKey: 'k1',
        kind: 'event',
        captureSessionId: 'cap-1',
        payloadJson: {'id': 'e1', 'type': 'tap'},
        createdAt: DateTime.now().toUtc(),
      ),
    );
    await store.clear();
    expect(store.pending(), isEmpty);
    final reloaded = TugboatOutboxStore(
      config: TugboatOutboxConfig(enabled: true, directory: dir),
    );
    await reloaded.load();
    expect(reloaded.pending(), isEmpty);
  });
}
