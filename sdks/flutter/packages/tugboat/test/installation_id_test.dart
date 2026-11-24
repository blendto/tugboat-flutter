import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_host.dart';
import 'package:tugboat/src/installation_id.dart';

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tugboat_installation_id');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  TugboatInstallationIdStore store({Random? random}) =>
      TugboatInstallationIdStore(directory: () async => root, random: random);

  File idFile() => File(
    '${root.path}/${TugboatInstallationIdStore.directoryName}/'
    '${TugboatInstallationIdStore.fileName}',
  );

  group('generateTugboatUuidV4', () {
    test('is a lowercase version 4 UUID', () {
      for (var i = 0; i < 200; i++) {
        expect(generateTugboatUuidV4(), matches(_uuidV4));
      }
    });

    test('differs between calls', () {
      final ids = {for (var i = 0; i < 500; i++) generateTugboatUuidV4()};
      expect(ids, hasLength(500));
    });
  });

  group('TugboatInstallationIdStore', () {
    test('mints a UUID on first launch and persists it', () async {
      final id = await store().read();

      expect(id, matches(_uuidV4));
      expect(await idFile().readAsString(), id);
    });

    test('a later launch reads the persisted id back', () async {
      final first = await store().read();
      final second = await store().read();

      expect(second, first);
    });

    test('repeated reads in one process return the first result', () async {
      final s = store();
      final results = await Future.wait([s.read(), s.read(), s.read()]);

      expect(results.toSet(), hasLength(1));
    });

    test('seeds the first id when nothing is persisted', () async {
      const vendorId = 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F';

      final id = await store().read(seed: vendorId);

      expect(id, vendorId);
      expect(await idFile().readAsString(), vendorId);
    });

    test('a persisted id wins over a seed', () async {
      final first = await store().read();

      final later = await store().read(seed: 'NEW-VENDOR-ID');

      expect(later, first);
    });

    test('an empty seed is ignored and a UUID is minted', () async {
      expect(await store().read(seed: '  '), matches(_uuidV4));
    });

    test('a reinstall (no file) mints a new id', () async {
      final first = await store().read();
      await root.delete(recursive: true);
      await root.create();

      final second = await store().read();

      expect(second, matches(_uuidV4));
      expect(second, isNot(first));
    });

    test('an empty or oversized file is replaced', () async {
      await idFile().parent.create(recursive: true);
      await idFile().writeAsString('');
      final fromEmpty = await store().read();
      expect(fromEmpty, matches(_uuidV4));

      await idFile().writeAsString(
        'x' * (TugboatInstallationIdStore.maxLength + 1),
      );
      final fromOversized = await store().read();
      expect(fromOversized, matches(_uuidV4));
      expect(await idFile().readAsString(), fromOversized);
    });

    test('a directory failure still returns an id and stays stable '
        'for the process', () async {
      final s = TugboatInstallationIdStore(
        directory: () async => throw const FileSystemException('no dir'),
      );

      final first = await s.read();
      final second = await s.read();

      expect(first, matches(_uuidV4));
      expect(second, first);
    });

    test('an unwritable directory still returns an id', () async {
      // A file where the tugboat directory should be makes the write fail.
      await File(
        '${root.path}/${TugboatInstallationIdStore.directoryName}',
      ).writeAsString('blocker');

      expect(await store().read(), matches(_uuidV4));
    });
  });

  group('resolveTugboatInstallationId', () {
    Future<String> sdkId() async => 'sdk-id';

    test('a non-empty host id wins', () async {
      expect(
        await resolveTugboatInstallationId(
          hostInstallationId: 'host-id',
          sdkInstallationId: sdkId,
        ),
        'host-id',
      );
    });

    test('null or blank host id falls back to the SDK id', () async {
      for (final host in [null, '', '   ']) {
        expect(
          await resolveTugboatInstallationId(
            hostInstallationId: host,
            sdkInstallationId: sdkId,
          ),
          'sdk-id',
        );
      }
    });

    test('the SDK id is not read when the host passes one', () async {
      var reads = 0;
      await resolveTugboatInstallationId(
        hostInstallationId: 'host-id',
        sdkInstallationId: () async {
          reads++;
          return 'sdk-id';
        },
      );
      expect(reads, 0);
    });
  });

  group('TugboatCollectorHost.installationId', () {
    test('returns the persisted SDK id', () async {
      TugboatCollectorHost.debugInstallationIdStore = store();

      final id = await TugboatCollectorHost.installationId();

      expect(id, matches(_uuidV4));
      expect(await idFile().readAsString(), id);
    });
  });
}
