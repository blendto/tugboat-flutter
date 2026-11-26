import 'dart:async';
import 'dart:convert';
import 'dart:io' show ProcessInfo;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:tugboat/tugboat.dart';

/// Screenshot backend selected with `--dart-define=TUGBOAT_BACKEND=<name>`.
///
/// Accepts `flutterRepaintBoundary` (default) or `nativeCpuExperimental`.
final TugboatScreenshotCaptureBackend profileBackend =
    TugboatScreenshotCaptureBackend.tryParse(
      const String.fromEnvironment('TUGBOAT_BACKEND'),
    ) ??
    TugboatScreenshotCaptureBackend.flutterRepaintBoundary;

/// Enabled with `--dart-define=TUGBOAT_PROFILE=true`. Off in normal runs.
const bool profilingEnabled = bool.fromEnvironment('TUGBOAT_PROFILE');

/// Collects capture cost, UI frame timings and RSS for backend comparisons.
///
/// Only bounded numbers are kept: no frame bytes, no event payloads beyond
/// the closed `capture_diagnostic` fields.
class CaptureProfiler implements TugboatCaptureSinkFactory {
  CaptureProfiler._();

  static final CaptureProfiler instance = CaptureProfiler._();

  final List<Map<String, Object?>> _frames = [];
  final Map<String, Map<String, Object?>> _diagnosticsByFrame = {};
  final Map<String, int> _outcomes = {};
  final List<FrameTiming> _uiFrames = [];
  final List<int> _rssSamples = [];
  bool _started = false;

  /// Starts UI-frame and RSS sampling. Safe to call more than once.
  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_uiFrames.addAll);
    Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _rssSamples.add(ProcessInfo.currentRss),
    );
  }

  /// Drops everything collected so far, e.g. after app warm-up.
  void reset() {
    _frames.clear();
    _diagnosticsByFrame.clear();
    _outcomes.clear();
    _uiFrames.clear();
    _rssSamples.clear();
  }

  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) =>
      _ProfilingSink(this);

  void _accept(TugboatCaptureEnvelope envelope) {
    final frame = envelope.frame;
    if (envelope.kind == TugboatEnvelopeKind.frame && frame != null) {
      _frames.add({
        'id': frame.id,
        'trigger': frame.trigger.name,
        'captureMicros': frame.captureMicros,
        'byteLength': frame.byteLength,
        'width': frame.width,
        'height': frame.height,
        'resolvedBackend': frame.resolvedBackend?.name,
        'fallbackReason': frame.fallbackReason,
      });
      return;
    }
    final event = envelope.event;
    if (event == null || event.type != 'capture_diagnostic') return;
    final data = event.data;
    final outcome = data['outcome'] as String? ?? 'unknown';
    _outcomes[outcome] = (_outcomes[outcome] ?? 0) + 1;
    final frameId = event.afterFrame;
    if (frameId != null) _diagnosticsByFrame[frameId] = data;
  }

  /// Percentile summary of everything recorded since the last [reset].
  Map<String, Object?> summary({String? label}) {
    final freshFrames = _frames
        .where((f) => (f['captureMicros'] as int) > 0)
        .toList();
    final nativeStage = <String, List<int>>{};
    for (final frame in freshFrames) {
      final diag = _diagnosticsByFrame[frame['id']];
      if (diag == null) continue;
      for (final key in const [
        'surfaceCopyMicros',
        'maskFillMicros',
        'dHashMicros',
        'jpegMicros',
        'sha256Micros',
        'pixelReadbackMicros',
        'platformChannelMicros',
      ]) {
        final value = diag[key];
        if (value is int) (nativeStage[key] ??= []).add(value);
      }
    }
    final fallbacks = <String, int>{};
    final resolved = <String, int>{};
    for (final frame in _frames) {
      final reason = frame['fallbackReason'] as String?;
      if (reason != null) fallbacks[reason] = (fallbacks[reason] ?? 0) + 1;
      final backend = frame['resolvedBackend'] as String? ?? 'unknown';
      resolved[backend] = (resolved[backend] ?? 0) + 1;
    }
    const frameBudgetMicros = 16667;
    final build = _uiFrames.map((t) => t.buildDuration.inMicroseconds).toList();
    final raster = _uiFrames
        .map((t) => t.rasterDuration.inMicroseconds)
        .toList();
    final jank = _uiFrames
        .where(
          (t) =>
              t.buildDuration.inMicroseconds > frameBudgetMicros ||
              t.rasterDuration.inMicroseconds > frameBudgetMicros,
        )
        .length;
    return {
      if (label != null) 'label': label,
      'requestedBackend': profileBackend.name,
      'mode': kProfileMode
          ? 'profile'
          : kReleaseMode
          ? 'release'
          : 'debug',
      'frames': _frames.length,
      'resolvedBackends': resolved,
      'fallbacks': fallbacks,
      'diagnosticOutcomes': Map.of(_outcomes),
      'captureMicros': _stats(
        freshFrames.map((f) => f['captureMicros'] as int).toList(),
      ),
      'jpegBytes': _stats(
        freshFrames.map((f) => f['byteLength'] as int).toList(),
      ),
      'nativeStageMicros': {
        for (final entry in nativeStage.entries) entry.key: _stats(entry.value),
      },
      'uiFrames': _uiFrames.length,
      'uiJankFrames': jank,
      'uiBuildMicros': _stats(build),
      'uiRasterMicros': _stats(raster),
      'rssBytes': _stats(_rssSamples),
      'processMaxRssBytes': ProcessInfo.maxRss,
    };
  }

  /// Prints [summary] as one `TBPROF` JSON line for log scraping.
  void printSummary({String? label}) =>
      debugPrint('TBPROF ${jsonEncode(summary(label: label))}');

  static Map<String, int> _stats(List<int> values) {
    if (values.isEmpty) return const {'n': 0};
    final sorted = [...values]..sort();
    int pct(double p) =>
        sorted[((sorted.length - 1) * p).round().clamp(0, sorted.length - 1)];
    return {
      'n': sorted.length,
      'p50': pct(0.5),
      'p90': pct(0.9),
      'p95': pct(0.95),
      'max': sorted.last,
      'mean': sorted.reduce((a, b) => a + b) ~/ sorted.length,
    };
  }
}

class _ProfilingSink implements TugboatSessionCaptureSink {
  _ProfilingSink(this._profiler);

  final CaptureProfiler _profiler;

  @override
  Future<void> start(TugboatSinkSessionContext context) async {}

  @override
  void accept(TugboatCaptureEnvelope envelope) => _profiler._accept(envelope);

  @override
  Future<void> flush() async {}

  @override
  Future<void> finish() async {}

  @override
  Future<void> dispose() async {}
}
