import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'native_capture.g.dart';

final NativeCaptureCapabilities kNativeCaptureUnsupported =
    NativeCaptureCapabilities(
      nativeCaptureSupported: false,
      apiLevel: 0,
      minNativeApi: 24,
    );

NativeCaptureTimings emptyNativeTimings() => NativeCaptureTimings(
  surfaceCopyMicros: 0,
  maskFillMicros: 0,
  dHashMicros: 0,
  jpegMicros: 0,
  sha256Micros: 0,
  pixelReadbackMicros: 0,
);

NativeCaptureResult nativeCaptureResult({
  required int requestId,
  required NativeCaptureStatus status,
  NativeCaptureCoverage? coverage,
  Uint8List? jpeg,
  int width = 0,
  int height = 0,
  String dHash = '',
  String contentHash = '',
  NativeCaptureTimings? timings,
  NativeCaptureRenderMode renderMode = NativeCaptureRenderMode.unknown,
  bool incomplete = false,
}) {
  return NativeCaptureResult(
    requestId: requestId,
    status: status,
    coverage: coverage,
    jpeg: jpeg ?? Uint8List(0),
    width: width,
    height: height,
    dHash: dHash,
    contentHash: contentHash,
    timings: timings ?? emptyNativeTimings(),
    renderMode: renderMode,
    incomplete: incomplete,
  );
}

bool nativeStatusFallsBack(NativeCaptureStatus status) => switch (status) {
  NativeCaptureStatus.unsupportedApi ||
  NativeCaptureStatus.unsupportedRenderMode ||
  NativeCaptureStatus.surfaceUnavailable ||
  NativeCaptureStatus.timeout ||
  NativeCaptureStatus.pixelCopyFailed ||
  NativeCaptureStatus.processingFailed => true,
  NativeCaptureStatus.ok ||
  NativeCaptureStatus.skippedByDHash ||
  NativeCaptureStatus.cancelled ||
  NativeCaptureStatus.disposed => false,
};

/// Host-side native capture. Missing plugins are treated as unsupported.
class NativeCaptureClient with WidgetsBindingObserver {
  NativeCaptureClient({
    NativeCaptureHostApi? api,
    bool observeLifecycle = false,
  }) : _api = api ?? NativeCaptureHostApi() {
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }
  }

  final NativeCaptureHostApi _api;
  static const _maxFallbackStreak = 3;

  int _nextRequestId = 1;
  int _fallbackStreak = 0;
  bool _disabledForSession = false;
  int? _inFlightId;
  bool _observingLifecycle = false;
  String? lastFallbackReason;
  NativeCaptureCapabilities? _cachedCapabilities;

  int allocateRequestId() => _nextRequestId++;

  bool get isDisabled => _disabledForSession;

  void resetSession() {
    _fallbackStreak = 0;
    _disabledForSession = false;
    _inFlightId = null;
    lastFallbackReason = null;
    _cachedCapabilities = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      resetSession();
    }
  }

  Future<NativeCaptureCapabilities> capabilities() async {
    final cached = _cachedCapabilities;
    if (cached != null) return cached;
    try {
      final value = await _api.getCapabilities();
      _cachedCapabilities = value;
      return value;
    } on MissingPluginException {
      return _cacheUnsupported();
    } on PlatformException {
      return _cacheUnsupported();
    }
  }

  Future<NativeCaptureResult> capture(NativeCaptureRequest request) async {
    if (_disabledForSession) {
      return nativeCaptureResult(
        requestId: request.requestId,
        status: NativeCaptureStatus.processingFailed,
      );
    }
    _inFlightId = request.requestId;
    try {
      return await _invokeCapture(request);
    } finally {
      if (_inFlightId == request.requestId) {
        _inFlightId = null;
      }
    }
  }

  Future<NativeCaptureResult> _invokeCapture(
    NativeCaptureRequest request,
  ) async {
    try {
      final reply = await _api.capture(request);
      return _finishReply(request.requestId, reply);
    } on MissingPluginException {
      return _fallbackReply(
        request.requestId,
        NativeCaptureStatus.unsupportedApi,
      );
    } on PlatformException {
      return _fallbackReply(
        request.requestId,
        NativeCaptureStatus.unsupportedApi,
      );
    }
  }

  NativeCaptureResult _finishReply(int requestId, NativeCaptureResult reply) {
    if (_inFlightId != requestId || reply.requestId != requestId) {
      return nativeCaptureResult(
        requestId: requestId,
        status: NativeCaptureStatus.cancelled,
      );
    }
    if (nativeStatusFallsBack(reply.status)) {
      _noteFallback(reply.status.name);
    } else {
      _fallbackStreak = 0;
      lastFallbackReason = null;
    }
    return reply;
  }

  NativeCaptureResult _fallbackReply(
    int requestId,
    NativeCaptureStatus status,
  ) {
    _noteFallback(status.name);
    return nativeCaptureResult(requestId: requestId, status: status);
  }

  Future<void> cancel(int requestId) async {
    _inFlightId = null;
    try {
      await _api.cancel(requestId);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<void> dispose() async {
    _inFlightId = null;
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    try {
      await _api.dispose();
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  NativeCaptureCapabilities _cacheUnsupported() {
    _cachedCapabilities = kNativeCaptureUnsupported;
    return kNativeCaptureUnsupported;
  }

  void _noteFallback(String reason) {
    lastFallbackReason = reason;
    _fallbackStreak += 1;
    if (_fallbackStreak >= _maxFallbackStreak) {
      _disabledForSession = true;
    }
  }
}
