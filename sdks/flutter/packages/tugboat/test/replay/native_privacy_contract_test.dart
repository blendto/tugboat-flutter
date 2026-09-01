import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/capture_boundary.dart';
import 'package:tugboat/src/markers.dart';
import 'package:tugboat/src/native_capture.g.dart';
import 'package:tugboat/src/native_capture_client.dart';
import 'package:tugboat/src/screenshot_capture_backend.dart';
import 'package:tugboat/src/screenshot_capturer.dart';
import 'package:tugboat/src/screenshot_encode.dart';
import 'package:tugboat/src/screenshot_mask_level.dart';

class _FakeHostApi extends NativeCaptureHostApi {
  _FakeHostApi(this.captureHandler);

  final Future<NativeCaptureResult> Function(NativeCaptureRequest request)
  captureHandler;
  final capturedRequests = <NativeCaptureRequest>[];

  @override
  Future<NativeCaptureCapabilities> getCapabilities() async {
    return NativeCaptureCapabilities(
      nativeCaptureSupported: true,
      apiLevel: 34,
      minNativeApi: 24,
    );
  }

  @override
  Future<NativeCaptureResult> capture(NativeCaptureRequest request) async {
    capturedRequests.add(request);
    return captureHandler(request);
  }
}

Float64List _nativeMappedRects(
  List<NativeCaptureMask> masks,
  int width,
  int height,
) {
  final packed = <double>[];
  for (final mask in masks) {
    if (mask.width <= 0 || mask.height <= 0) continue;
    final left = (mask.x * width).floor().clamp(0, width);
    final top = (mask.y * height).floor().clamp(0, height);
    final right = ((mask.x + mask.width) * width).ceil().clamp(0, width);
    final bottom = ((mask.y + mask.height) * height).ceil().clamp(0, height);
    if (right <= left || bottom <= top) continue;
    packed.addAll([
      left.toDouble(),
      top.toDouble(),
      right.toDouble(),
      bottom.toDouble(),
    ]);
  }
  return Float64List.fromList(packed);
}

Uint8List _redBuffer(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = 255;
    rgba[i + 1] = 0;
    rgba[i + 2] = 0;
    rgba[i + 3] = 255;
  }
  return rgba;
}

NativeCaptureResult _maskedJpegReply(NativeCaptureRequest request) {
  final rgba = _redBuffer(request.pixelWidth, request.pixelHeight);
  final mapped = _nativeMappedRects(
    request.masks,
    request.pixelWidth,
    request.pixelHeight,
  );
  final encoded = encodeScreenshotRgba(
    ScreenshotEncodeInput(
      rgba: rgba,
      width: request.pixelWidth,
      height: request.pixelHeight,
      maskRects: mapped,
      lastDHash: request.lastDHash.isEmpty ? null : request.lastDHash,
      force: request.force,
    ),
  );
  return nativeCaptureResult(
    requestId: request.requestId,
    status: encoded.skippedByDHash
        ? NativeCaptureStatus.skippedByDHash
        : NativeCaptureStatus.ok,
    jpeg: encoded.bytes,
    width: request.pixelWidth,
    height: request.pixelHeight,
    dHash: encoded.dHash ?? '',
    contentHash: encoded.contentHash,
    coverage: NativeCaptureCoverage.engineSurface,
  );
}

void main() {
  test('native capture request carries no pixel buffer', () {
    final request = NativeCaptureRequest(
      requestId: 1,
      pixelWidth: 8,
      pixelHeight: 8,
      force: true,
      lastDHash: '0' * 64,
      masks: [NativeCaptureMask(x: 0, y: 0, width: 0.5, height: 0.5)],
    );
    final encoded = request.encode();
    expect(encoded, isA<List<Object?>>());
    final values = encoded as List<Object?>;
    expect(values.any((value) => value is Uint8List), isFalse);
    expect(values[0], 1);
    expect(values[3], isTrue);
    expect(values[4], '0' * 64);
  });

  test('native mapping keeps edge and overlapping masks opaque', () {
    final rgba = _redBuffer(10, 10);
    final mapped = _nativeMappedRects(
      [
        NativeCaptureMask(x: 0, y: 0, width: 0.2, height: 0.2),
        NativeCaptureMask(x: 0.8, y: 0.8, width: 0.2, height: 0.2),
        NativeCaptureMask(x: -0.1, y: 0.4, width: 0.3, height: 0.2),
      ],
      10,
      10,
    );
    applyMaskRectsInPlace(rgba: rgba, width: 10, height: 10, maskRects: mapped);
    expect(rgba[0], 0x1a);
    expect(rgba[(9 * 10 + 9) * 4], 0x1a);
    expect(rgba[(5 * 10 + 5) * 4], 255);
  });

  testWidgets('native backend masks known private tiles in the returned JPEG', (
    tester,
  ) async {
    final api = _FakeHostApi((request) async => _maskedJpegReply(request));
    final boundaryKey = GlobalKey();
    final capturer = ScreenshotCapturer(
      boundaryKey: boundaryKey,
      maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
      anchorResolver: AnchorResolver(rootKey: boundaryKey),
      pixelRatio: 1,
      screenshotCaptureBackend:
          TugboatScreenshotCaptureBackend.nativeCpuExperimental,
      nativeClient: NativeCaptureClient(api: api),
      frameWaiter: () async {},
    );
    addTearDown(capturer.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: TugboatCaptureBoundary(
            key: boundaryKey,
            child: const SizedBox(
              width: 80,
              height: 80,
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: Color(0xffff0000))),
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 20,
                    height: 20,
                    child: TugboatSensitive(
                      child: ColoredBox(color: Color(0xff00ff00)),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    width: 20,
                    height: 20,
                    child: TugboatSensitive(
                      child: ColoredBox(color: Color(0xff0000ff)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final attempt = await capturer.captureAttempt(
      force: true,
      waitForFrame: false,
    );
    expect(attempt.failure, isNull);
    expect(api.capturedRequests, hasLength(1));
    final sent = api.capturedRequests.single;
    expect(sent.force, isTrue);
    expect(sent.masks, hasLength(2));
    expect(sent.encode(), isA<List<Object?>>());
    expect(
      (sent.encode() as List<Object?>).any((value) => value is Uint8List),
      isFalse,
    );

    final decoded = img.decodeJpg(attempt.result!.bytes)!;
    expect(decoded.width, 80);
    expect(decoded.height, 80);
    final secret = decoded.getPixel(4, 4);
    final public = decoded.getPixel(40, 40);
    final edge = decoded.getPixel(75, 75);
    expect(secret.r.toInt(), closeTo(0x1a, 2));
    expect(secret.g.toInt(), closeTo(0x1a, 2));
    expect(secret.b.toInt(), closeTo(0x1a, 2));
    expect(edge.r.toInt(), closeTo(0x1a, 2));
    expect(public.r.toInt(), greaterThan(200));
    expect(attempt.result!.contentHash, isNotEmpty);
    expect(attempt.result!.dHash, hasLength(64));
  });

  testWidgets('native masks stay opaque at each capture scale', (tester) async {
    for (final ratio in <double>[0.5, 0.75, 1.0, 1.5]) {
      await _expectNativeMasks(
        tester,
        capturePixelRatio: ratio,
        canvas: const Size(80, 80),
      );
    }
  });

  testWidgets('native masks stay opaque after density changes', (tester) async {
    const physical = Size(240, 240);
    for (final dpr in <double>[1.0, 2.0, 3.0]) {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = physical;
      await _expectNativeMasks(
        tester,
        capturePixelRatio: 1,
        canvas: Size(physical.width / dpr, physical.height / dpr),
      );
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('native masks stay opaque after a landscape layout', (
    tester,
  ) async {
    await _expectNativeMasks(
      tester,
      capturePixelRatio: 1,
      canvas: const Size(160, 80),
    );
  });

  testWidgets('native masks stay opaque after keyboard-style view insets', (
    tester,
  ) async {
    await _expectNativeMasks(
      tester,
      capturePixelRatio: 1,
      canvas: const Size(80, 80),
      viewInsets: const EdgeInsets.only(bottom: 24),
    );
  });
}

Future<void> _expectNativeMasks(
  WidgetTester tester, {
  required double capturePixelRatio,
  required Size canvas,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) async {
  final api = _FakeHostApi((request) async => _maskedJpegReply(request));
  final boundaryKey = GlobalKey();
  final capturer = ScreenshotCapturer(
    boundaryKey: boundaryKey,
    maskLevel: TugboatScreenshotMaskLevel.explicitOnly,
    anchorResolver: AnchorResolver(rootKey: boundaryKey),
    pixelRatio: capturePixelRatio,
    screenshotCaptureBackend:
        TugboatScreenshotCaptureBackend.nativeCpuExperimental,
    nativeClient: NativeCaptureClient(api: api),
    frameWaiter: () async {},
  );
  addTearDown(capturer.dispose);

  final innerHeight = canvas.height - viewInsets.bottom;
  final secret = canvas.shortestSide * 0.25;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: canvas,
        viewInsets: viewInsets,
        padding: viewInsets,
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: TugboatCaptureBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: canvas.width,
              height: innerHeight,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: ColoredBox(color: Color(0xffff0000)),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    width: secret,
                    height: secret,
                    child: const TugboatSensitive(
                      child: ColoredBox(color: Color(0xff00ff00)),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    width: secret,
                    height: secret,
                    child: const TugboatSensitive(
                      child: ColoredBox(color: Color(0xff0000ff)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  final attempt = await capturer.captureAttempt(
    force: true,
    waitForFrame: false,
  );
  expect(attempt.failure, isNull, reason: 'capturePixelRatio=$capturePixelRatio');
  final jpeg = attempt.result!.bytes;
  final decoded = img.decodeJpg(jpeg)!;
  expect(decoded.width, greaterThan(0));
  expect(decoded.height, greaterThan(0));
  final secretPx = decoded.getPixel(1, 1);
  final publicPx = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
  final edgePx = decoded.getPixel(decoded.width - 2, decoded.height - 2);
  expect(secretPx.r.toInt(), closeTo(0x1a, 2));
  expect(secretPx.g.toInt(), closeTo(0x1a, 2));
  expect(edgePx.r.toInt(), closeTo(0x1a, 2));
  expect(publicPx.r.toInt(), greaterThan(200));
}
