import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/capture_boundary.dart';
import 'package:tugboat/src/native_capture.g.dart';
import 'package:tugboat/src/native_capture_client.dart';
import 'package:tugboat/src/native_cpu_pixel_source.dart';
import 'package:tugboat/src/screenshot_capture_backend.dart';
import 'package:tugboat/src/screenshot_capturer.dart';
import 'package:tugboat/src/screenshot_encode.dart';
import 'package:tugboat/src/screenshot_mask_level.dart';
import 'package:tugboat/src/screenshot_pixel_source.dart';

class _FakeHostApi extends NativeCaptureHostApi {
  _FakeHostApi({this.caps, this.captureHandler});

  NativeCaptureCapabilities? caps;
  Future<NativeCaptureResult> Function(NativeCaptureRequest request)?
  captureHandler;
  final capturedRequests = <NativeCaptureRequest>[];
  var disposeCount = 0;

  @override
  Future<NativeCaptureCapabilities> getCapabilities() async {
    return caps ??
        NativeCaptureCapabilities(
          nativeCaptureSupported: true,
          apiLevel: 34,
          minNativeApi: 24,
        );
  }

  @override
  Future<NativeCaptureResult> capture(NativeCaptureRequest request) async {
    capturedRequests.add(request);
    return captureHandler!(request);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
  }
}

class _RecordingFallback implements ScreenshotPixelSource {
  var calls = 0;
  String? lastFallbackReason;

  @override
  Future<ScreenshotPixelAcquisition> acquire(
    ScreenshotPixelRequest request,
  ) async {
    calls += 1;
    lastFallbackReason = request.fallbackReason;
    return ScreenshotPixelAcquisition(
      disposition: ScreenshotPixelDisposition.captured,
      bytes: Uint8List.fromList(const [9, 9, 9]),
      contentHash: 'fallback',
      width: request.pixelWidth,
      height: request.pixelHeight,
      trace: ScreenshotBackendTrace.flutter(
        requested: request.requestedBackend,
        fallbackReason: request.fallbackReason,
      ),
    );
  }

  @override
  void resetSession() {}

  @override
  Future<void> dispose() async {}
}

class _ThrowingEncoder implements ScreenshotEncoder {
  @override
  Future<ScreenshotEncodeResult> encode(ScreenshotEncodeInput input) async {
    fail('Flutter encoder must not run on a successful native capture');
  }

  @override
  Future<void> dispose() async {}
}

NativeCaptureRequest _request({int requestId = 1}) => NativeCaptureRequest(
  requestId: requestId,
  pixelWidth: 8,
  pixelHeight: 8,
  force: false,
  lastDHash: '',
  masks: <NativeCaptureMask>[],
);

ScreenshotPixelRequest _pixelRequest({
  required RenderRepaintBoundary boundary,
  String? fallbackReason,
}) {
  return ScreenshotPixelRequest(
    boundary: boundary,
    capturePixelRatio: 1,
    pixelWidth: 8,
    pixelHeight: 8,
    logicalSize: const Size(8, 8),
    maskRects: const [Rect.fromLTWH(0, 0, 4, 4)],
    lastDHash: '',
    force: true,
    requestedBackend: TugboatScreenshotCaptureBackend.nativeCpuExperimental,
    fallbackReason: fallbackReason,
  );
}

void main() {
  test('tryParse accepts closed backend names and ignores unknown values', () {
    expect(
      TugboatScreenshotCaptureBackend.tryParse('flutterRepaintBoundary'),
      TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
    );
    expect(
      TugboatScreenshotCaptureBackend.tryParse('nativeCpuExperimental'),
      TugboatScreenshotCaptureBackend.nativeCpuExperimental,
    );
    expect(TugboatScreenshotCaptureBackend.tryParse(null), isNull);
    expect(TugboatScreenshotCaptureBackend.tryParse('gpuExperimental'), isNull);
  });

  test(
    'native success returns JPEG and does not call Flutter fallback',
    () async {
      final jpeg = Uint8List.fromList(const [1, 2, 3, 4]);
      final api = _FakeHostApi(
        captureHandler: (request) async => nativeCaptureResult(
          requestId: request.requestId,
          status: NativeCaptureStatus.ok,
          jpeg: jpeg,
          width: 8,
          height: 8,
          dHash: '1' * 64,
          contentHash: 'abc',
          coverage: NativeCaptureCoverage.engineSurface,
        ),
      );
      final fallback = _RecordingFallback();
      final source = NativeCpuExperimentalPixelSource(
        client: NativeCaptureClient(api: api),
        fallback: fallback,
      );
      final boundary = RenderRepaintBoundary();
      final result = await source.acquire(_pixelRequest(boundary: boundary));

      expect(fallback.calls, 0);
      expect(result.disposition, ScreenshotPixelDisposition.captured);
      expect(result.bytes, jpeg);
      expect(
        result.trace.resolved,
        TugboatScreenshotCaptureBackend.nativeCpuExperimental,
      );
      expect(result.trace.coverage, 'engineSurface');
      expect(api.capturedRequests, hasLength(1));
      final sent = api.capturedRequests.single;
      expect(sent.pixelWidth, 8);
      expect(sent.masks, hasLength(1));
      expect(sent.masks.single.x, 0);
      expect(sent.masks.single.width, 0.5);
    },
  );

  test(
    'native encodeMicros is the platform-channel clock, not nested stages',
    () async {
      const nestedStages =
          3317 + 1 + 133 + 828 + 199; // surface, mask, dHash, jpeg, sha256
      final api = _FakeHostApi(
        captureHandler: (request) async => nativeCaptureResult(
          requestId: request.requestId,
          status: NativeCaptureStatus.ok,
          jpeg: Uint8List.fromList(const [1, 2, 3, 4]),
          width: 8,
          height: 8,
          dHash: '1' * 64,
          contentHash: 'abc',
          coverage: NativeCaptureCoverage.engineSurface,
          timings: NativeCaptureTimings(
            surfaceCopyMicros: 3317,
            maskFillMicros: 1,
            dHashMicros: 133,
            jpegMicros: 828,
            sha256Micros: 199,
            pixelReadbackMicros: 0,
          ),
        ),
      );
      final source = NativeCpuExperimentalPixelSource(
        client: NativeCaptureClient(api: api),
        fallback: _RecordingFallback(),
      );

      final result = await source.acquire(
        _pixelRequest(boundary: RenderRepaintBoundary()),
      );

      expect(result.captureMicros, 0);
      expect(result.encodeMicros, result.trace.platformChannelMicros);
      expect(
        result.encodeMicros,
        isNot(nestedStages + result.trace.platformChannelMicros),
      );
      expect(result.trace.surfaceCopyMicros, 3317);
      expect(result.trace.jpegMicros, 828);
    },
  );

  test('native fallback status uses Flutter path once', () async {
    final api = _FakeHostApi(
      captureHandler: (request) async => nativeCaptureResult(
        requestId: request.requestId,
        status: NativeCaptureStatus.pixelCopyFailed,
      ),
    );
    final fallback = _RecordingFallback();
    final source = NativeCpuExperimentalPixelSource(
      client: NativeCaptureClient(api: api),
      fallback: fallback,
    );
    final result = await source.acquire(
      _pixelRequest(boundary: RenderRepaintBoundary()),
    );

    expect(fallback.calls, 1);
    expect(fallback.lastFallbackReason, 'pixelCopyFailed');
    expect(result.bytes, Uint8List.fromList(const [9, 9, 9]));
    expect(result.trace.fallbackReason, 'pixelCopyFailed');
    expect(
      result.trace.requested,
      TugboatScreenshotCaptureBackend.nativeCpuExperimental,
    );
    expect(
      result.trace.resolved,
      TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
    );
  });

  test('cancelled native result does not fall back', () async {
    final api = _FakeHostApi(
      captureHandler: (request) async => nativeCaptureResult(
        requestId: request.requestId,
        status: NativeCaptureStatus.cancelled,
      ),
    );
    final fallback = _RecordingFallback();
    final source = NativeCpuExperimentalPixelSource(
      client: NativeCaptureClient(api: api),
      fallback: fallback,
    );
    final result = await source.acquire(
      _pixelRequest(boundary: RenderRepaintBoundary()),
    );

    expect(fallback.calls, 0);
    expect(result.disposition, ScreenshotPixelDisposition.cancelled);
  });

  test('stale native replies are ignored without fallback', () async {
    final pending = Completer<NativeCaptureResult>();
    final api = _FakeHostApi(captureHandler: (_) => pending.future);
    final client = NativeCaptureClient(api: api);
    final request = _request(requestId: 11);
    final future = client.capture(request);
    await client.cancel(11);
    pending.complete(
      nativeCaptureResult(
        requestId: 11,
        status: NativeCaptureStatus.ok,
        jpeg: Uint8List.fromList(const [7, 7]),
      ),
    );
    final reply = await future;
    expect(reply.status, NativeCaptureStatus.cancelled);
    expect(reply.jpeg, isEmpty);
    expect(client.isDisabled, isFalse);
  });

  test('three fallbacks disable native for the session', () async {
    final api = _FakeHostApi(
      captureHandler: (request) async => nativeCaptureResult(
        requestId: request.requestId,
        status: NativeCaptureStatus.timeout,
      ),
    );
    final client = NativeCaptureClient(api: api);
    for (var i = 0; i < 3; i++) {
      final reply = await client.capture(_request(requestId: i + 1));
      expect(reply.status, NativeCaptureStatus.timeout);
    }
    expect(client.isDisabled, isTrue);
    client.resetSession();
    expect(client.isDisabled, isFalse);
  });

  test('unsupported capabilities skip native without sending pixels', () async {
    final api = _FakeHostApi(
      caps: kNativeCaptureUnsupported,
      captureHandler: (_) async {
        fail('capture must not run when capabilities are unsupported');
      },
    );
    final fallback = _RecordingFallback();
    final source = NativeCpuExperimentalPixelSource(
      client: NativeCaptureClient(api: api),
      fallback: fallback,
    );
    await source.acquire(_pixelRequest(boundary: RenderRepaintBoundary()));
    expect(api.capturedRequests, isEmpty);
    expect(fallback.calls, 1);
    expect(fallback.lastFallbackReason, 'unsupportedApi');
  });

  test('normalizeMaskRects uses CaptureBoundary local space', () {
    final masks = normalizeMaskRects(const [
      Rect.fromLTWH(10, 20, 30, 40),
      Rect.fromLTWH(0, 0, 0, 10),
    ], const Size(100, 200));
    expect(masks, hasLength(1));
    expect(masks.single.x, closeTo(0.1, 1e-9));
    expect(masks.single.y, closeTo(0.1, 1e-9));
    expect(masks.single.width, closeTo(0.3, 1e-9));
    expect(masks.single.height, closeTo(0.2, 1e-9));
  });

  testWidgets('native capturer publishes host JPEG without Flutter encode', (
    tester,
  ) async {
    final jpeg = Uint8List.fromList(List<int>.generate(24, (index) => index));
    final api = _FakeHostApi(
      captureHandler: (request) async => nativeCaptureResult(
        requestId: request.requestId,
        status: NativeCaptureStatus.ok,
        jpeg: jpeg,
        width: 80,
        height: 80,
        dHash: '0' * 64,
        contentHash: 'native-hash',
        coverage: NativeCaptureCoverage.engineSurface,
      ),
    );
    final boundaryKey = GlobalKey();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      pixelRatio: 1,
      screenshotCaptureBackend:
          TugboatScreenshotCaptureBackend.nativeCpuExperimental,
      nativeClient: NativeCaptureClient(api: api),
      encoder: _ThrowingEncoder(),
      frameWaiter: () async {},
    );
    addTearDown(capturer.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: TugboatCaptureBoundary(
          key: boundaryKey,
          child: const SizedBox.square(dimension: 80),
        ),
      ),
    );

    final attempt = await capturer.captureAttempt(
      force: true,
      waitForFrame: false,
    );
    expect(attempt.failure, isNull);
    expect(attempt.result!.bytes, jpeg);
    expect(attempt.result!.contentHash, 'native-hash');
    expect(
      attempt.result!.backendTrace.resolved,
      TugboatScreenshotCaptureBackend.nativeCpuExperimental,
    );
    expect(
      attempt.result!.backendTrace.requested,
      TugboatScreenshotCaptureBackend.nativeCpuExperimental,
    );
    expect(attempt.result!.backendTrace.fallbackReason, isNull);
    expect(api.capturedRequests, hasLength(1));
  });
}
