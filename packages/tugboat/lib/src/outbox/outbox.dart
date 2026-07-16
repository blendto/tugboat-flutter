import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Opt-in durable delivery configuration (Collector HTTP only).
class TugboatOutboxConfig {
  const TugboatOutboxConfig({
    this.enabled = false,
    this.maxBytes = 5 * 1024 * 1024,
    this.maxEntries = 500,
    this.maxAge = const Duration(days: 7),
    this.directory,
  });

  final bool enabled;
  final int maxBytes;
  final int maxEntries;
  final Duration maxAge;

  /// Override store directory (tests). Null → application support subdir.
  final Directory? directory;

  static const disabled = TugboatOutboxConfig();
}

/// Versioned minimized delivery envelope persisted before network send.
class TugboatOutboxEnvelope {
  TugboatOutboxEnvelope({
    required this.idempotencyKey,
    required this.kind,
    required this.captureSessionId,
    required this.payloadJson,
    required this.createdAt,
    this.activationRequestId,
    this.attemptCount = 0,
    this.payloadBytes,
  });

  static const schemaVersion = 1;

  final String idempotencyKey;
  final String kind; // event_batch | frame | session_lifecycle
  final String captureSessionId;
  final String? activationRequestId;
  final Map<String, Object?> payloadJson;
  final DateTime createdAt;
  int attemptCount;
  final Uint8List? payloadBytes;

  int get estimatedBytes {
    final jsonBytes = utf8.encode(jsonEncode(payloadJson)).length;
    return jsonBytes + (payloadBytes?.length ?? 0) + 128;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'idempotencyKey': idempotencyKey,
    'kind': kind,
    'captureSessionId': captureSessionId,
    if (activationRequestId != null) 'activationRequestId': activationRequestId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'attemptCount': attemptCount,
    'payload': payloadJson,
    if (payloadBytes != null) 'payloadBytesBase64': base64Encode(payloadBytes!),
  };

  factory TugboatOutboxEnvelope.fromJson(Map<String, Object?> json) {
    final version = json['schemaVersion'] as int? ?? 0;
    if (version != schemaVersion) {
      throw const FormatException('Unsupported outbox envelope version');
    }
    final bytesB64 = json['payloadBytesBase64'] as String?;
    return TugboatOutboxEnvelope(
      idempotencyKey: json['idempotencyKey'] as String,
      kind: json['kind'] as String,
      captureSessionId: json['captureSessionId'] as String,
      activationRequestId: json['activationRequestId'] as String?,
      payloadJson: Map<String, Object?>.from(json['payload'] as Map? ?? {}),
      createdAt: DateTime.parse(json['createdAt'] as String),
      attemptCount: json['attemptCount'] as int? ?? 0,
      payloadBytes: bytesB64 == null ? null : base64Decode(bytesB64),
    );
  }
}

/// Append-only file outbox with restart recovery and bounds.
class TugboatOutboxStore {
  TugboatOutboxStore({required this.config, Directory? directory})
    : _directory = directory ?? config.directory;

  final TugboatOutboxConfig config;
  Directory? _directory;
  final List<TugboatOutboxEnvelope> _entries = [];
  final Set<String> _acked = {};
  final List<String> _quarantineReasons = [];
  bool _loaded = false;

  int get entryCount => _entries.length;
  int get byteSize =>
      _entries.fold<int>(0, (sum, e) => sum + e.estimatedBytes);
  List<String> get quarantineReasons =>
      List<String>.unmodifiable(_quarantineReasons);

  Future<Directory> _resolveDir() async {
    final existing = _directory;
    if (existing != null) {
      if (!existing.existsSync()) {
        existing.createSync(recursive: true);
      }
      return existing;
    }
    final tmp = await Directory.systemTemp.createTemp('tugboat_outbox_');
    _directory = tmp;
    return tmp;
  }

  File _logFile(Directory dir) => File('${dir.path}/outbox.jsonl');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (!config.enabled) return;
    final dir = await _resolveDir();
    final file = _logFile(dir);
    if (!file.existsSync()) return;
    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        if (json['op'] == 'ack') {
          _acked.add(json['idempotencyKey'] as String);
          continue;
        }
        final envelope = TugboatOutboxEnvelope.fromJson(
          Map<String, Object?>.from(json),
        );
        if (_acked.contains(envelope.idempotencyKey)) continue;
        _entries.add(envelope);
      } catch (_) {
        _quarantineReasons.add('corrupt_line');
      }
    }
    _entries.removeWhere((e) => _acked.contains(e.idempotencyKey));
    await _enforceBounds();
  }

  Future<void> append(TugboatOutboxEnvelope envelope) async {
    if (!config.enabled) return;
    await load();
    if (_acked.contains(envelope.idempotencyKey)) return;
    if (_entries.any((e) => e.idempotencyKey == envelope.idempotencyKey)) {
      return;
    }
    _entries.add(envelope);
    final dir = await _resolveDir();
    final file = _logFile(dir);
    await file.writeAsString(
      '${jsonEncode(envelope.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
    await _enforceBounds();
  }

  Future<void> acknowledge(String idempotencyKey) async {
    if (!config.enabled) return;
    await load();
    _acked.add(idempotencyKey);
    _entries.removeWhere((e) => e.idempotencyKey == idempotencyKey);
    final dir = await _resolveDir();
    final file = _logFile(dir);
    await file.writeAsString(
      '${jsonEncode({'op': 'ack', 'idempotencyKey': idempotencyKey})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  List<TugboatOutboxEnvelope> pending() =>
      List<TugboatOutboxEnvelope>.unmodifiable(_entries);

  Future<void> clear() async {
    _entries.clear();
    _acked.clear();
    _quarantineReasons.clear();
    final dir = _directory;
    if (dir != null && dir.existsSync()) {
      final file = _logFile(dir);
      if (file.existsSync()) await file.delete();
    }
  }

  Future<void> _enforceBounds() async {
    final now = DateTime.now().toUtc();
    _entries.removeWhere(
      (e) => now.difference(e.createdAt) > config.maxAge,
    );
    while (_entries.length > config.maxEntries || byteSize > config.maxBytes) {
      if (_entries.isEmpty) break;
      _entries.removeAt(0);
    }
  }
}

/// Builds a stable idempotency key for a minimized payload.
String tugboatOutboxIdempotencyKey({
  required String kind,
  required String captureSessionId,
  required String body,
}) {
  final digest = sha256.convert(utf8.encode('$kind|$captureSessionId|$body'));
  return digest.toString();
}
