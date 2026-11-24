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
/// or written, the id is still returned and stays stable for this process,
/// but a later launch mints a new one.
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
  Future<String>? _resolved;

  /// The persisted id, minting and persisting one on first call.
  ///
  /// [seed] is used instead of a random UUID only when no id has been
  /// persisted yet (iOS passes `identifierForVendor`, so existing installs
  /// keep the value they already reported as `device.id`). Later calls in
  /// the same process return the first result.
  Future<String> read({String? seed}) => _resolved ??= _readOrMint(seed);

  Future<String> _readOrMint(String? seed) async {
    final file = await _file();
    final existing = await _readExisting(file);
    if (existing != null) return existing;
    final id = _usable(seed) ?? generateTugboatUuidV4(_random);
    if (file != null) await _persist(file, id);
    return id;
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

  static Future<void> _persist(File file, String id) async {
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(id, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // The id stays valid for this process; the next launch mints again.
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
