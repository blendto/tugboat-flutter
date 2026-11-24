import 'dart:io';
import 'dart:math';

/// Locates the directory that holds the SDK's own files.
typedef TugboatInstallationIdDirectory = Future<Directory> Function();

/// SDK-owned installation id: a random UUID minted on first launch and
/// persisted in the app's support directory, so it lasts across launches and
/// app updates and is new after a reinstall (or when app data is cleared).
///
/// The id lives in its own file (`tugboat/installation_id`), not in the
/// host's shared preferences, so a host that clears its preferences on
/// logout keeps the same installation id.
///
/// Persistence failures never interrupt the host: if the file cannot be read
/// or written, the id is still returned and stays stable for this process.
/// A failed write is retried on later reads, so a transient error (low disk
/// space, say) does not make every launch mint a new id. If nothing ever
/// persists, a later launch mints a new one.
///
/// When several stores (isolates, processes) race on first launch, the file
/// that ends up on disk wins and every store returns it.
class TugboatInstallationIdStore {
  TugboatInstallationIdStore({
    required TugboatInstallationIdDirectory directory,
    Random? random,
  }) : _directory = directory,
       _random = random ?? Random.secure();

  static const directoryName = 'tugboat';
  static const fileName = 'installation_id';

  /// Longest id read back from disk; anything longer is treated as corrupt.
  static const maxLength = 128;

  final TugboatInstallationIdDirectory _directory;
  final Random _random;
  Future<_Resolved>? _resolved;

  /// The persisted id, minting and persisting one on first call.
  ///
  /// [seed] is used instead of a random UUID only when no id has been
  /// persisted yet (iOS passes `identifierForVendor`, so existing installs
  /// keep the value they already reported as `device.id`). Later calls in
  /// the same process return the first result.
  Future<String> read({String? seed}) {
    final resolved = _resolved ??= _readOrMint(seed);
    return resolved.then((result) {
      // A result that never reached disk is retried on the next read; the
      // retry keeps the same id, so it stays stable within this process.
      if (!result.persisted) _resolved = _retry(result.id);
      return result.id;
    });
  }

  Future<_Resolved> _retry(String id) async {
    final file = await _file();
    final existing = await _readExisting(file);
    if (existing != null) return _Resolved(existing, persisted: true);
    return _store(file, id);
  }

  Future<_Resolved> _readOrMint(String? seed) async {
    final file = await _file();
    final existing = await _readExisting(file);
    if (existing != null) return _Resolved(existing, persisted: true);
    return _store(file, _usable(seed) ?? generateTugboatUuidV4(_random));
  }

  /// Persists [id] and returns the id on disk, so a store that lost a
  /// first-launch race adopts the winner's id.
  Future<_Resolved> _store(File? file, String id) async {
    if (file == null) return _Resolved(id, persisted: false);
    try {
      await file.parent.create(recursive: true);
      if (await _createExclusive(file, id)) {
        return _Resolved(id, persisted: true);
      }
      final winner = await _awaitWinner(file);
      if (winner != null) return _Resolved(winner, persisted: true);
      // The file exists but never became a usable id (a torn write from an
      // earlier launch): replace it.
      await file.delete();
      final won = await _createExclusive(file, id);
      return _Resolved(
        won ? id : (await _readExisting(file)) ?? id,
        persisted: won,
      );
    } catch (_) {
      // The id stays valid for this process; the write is retried on a
      // later read.
      return _Resolved(id, persisted: false);
    }
  }

  /// Creates [file] only if absent (atomically) and writes [id] to it.
  /// Returns false when another store created it first.
  static Future<bool> _createExclusive(File file, String id) async {
    try {
      await file.create(exclusive: true);
    } on PathExistsException {
      return false;
    }
    try {
      await file.writeAsString(id, flush: true);
    } catch (_) {
      await file.delete();
      rethrow;
    }
    return true;
  }

  /// Another store created the file; wait briefly for it to finish writing.
  static Future<String?> _awaitWinner(File file) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final id = await _readExisting(file);
      if (id != null) return id;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }

  Future<File?> _file() async {
    try {
      final dir = await _directory();
      return File('${dir.path}/$directoryName/$fileName');
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _readExisting(File? file) async {
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      return _usable(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  static String? _usable(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed.length > maxLength) {
      return null;
    }
    return trimmed;
  }
}

class _Resolved {
  const _Resolved(this.id, {required this.persisted});

  final String id;
  final bool persisted;
}

/// Picks the installation id a session reports: a non-empty id the host
/// passed wins; otherwise the SDK's own persisted id.
Future<String> resolveTugboatInstallationId({
  String? hostInstallationId,
  required Future<String> Function() sdkInstallationId,
}) async {
  final host = hostInstallationId?.trim();
  if (host != null && host.isNotEmpty) return host;
  return sdkInstallationId();
}

/// A random (version 4) UUID in lowercase canonical form.
String generateTugboatUuidV4([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
