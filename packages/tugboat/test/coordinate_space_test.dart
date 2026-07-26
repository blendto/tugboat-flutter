import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/coordinate_space.dart';
import 'package:tugboat/tugboat.dart';

void main() {
  test('round-trips transform with non-zero origin and non-uniform scale', () {
    final coord = buildCaptureCoordinate(
      globalX: 120,
      globalY: 240,
      boundaryOriginX: 20,
      boundaryOriginY: 40,
      boundaryWidth: 200,
      boundaryHeight: 400,
      framePixelWidth: 100,
      framePixelHeight: 800,
      frameId: 'frame-1',
      boundaryTransformGeneration: 3,
    );
    expect(coord.isAvailable, isTrue);
    expect(coord.localX, 100);
    expect(coord.localY, 200);
    expect(coord.normalizedX, 0.5);
    expect(coord.normalizedY, 0.5);
    expect(coord.effectiveScaleX, 0.5);
    expect(coord.effectiveScaleY, 2.0);

    final json = jsonDecode(jsonEncode(coord.toJson())) as Map<String, Object?>;
    final restored = TugboatCaptureCoordinate.fromJson(json);
    expect(restored.toJson(), coord.toJson());
    expect(restored.projectToRaster(), (x: 50, y: 400));
  });

  test('legacy events with only global x/y remain readable', () {
    final event = TugboatEvent(
      id: 'e1',
      atMs: 1,
      type: 'tap',
      data: const {'x': 10.5, 'y': 20.25},
    );
    final json = jsonDecode(jsonEncode(event.toJson())) as Map<String, Object?>;
    final data = Map<String, Object?>.from(json['data']! as Map);
    expect(data['x'], 10.5);
    expect(data['y'], 20.25);
    expect(data['captureCoordinate'], isNull);
  });

  test('rejects out-of-range normalized coordinates on projection', () {
    final bad = TugboatCaptureCoordinate(
      sourceSpace: TugboatCoordinateSourceSpace.boundaryLocalLogical,
      boundaryOriginX: 0,
      boundaryOriginY: 0,
      boundaryWidth: 100,
      boundaryHeight: 100,
      localX: 150,
      localY: 50,
      normalizedX: 1.5,
      normalizedY: 0.5,
      framePixelWidth: 100,
      framePixelHeight: 100,
      effectiveScaleX: 1,
      effectiveScaleY: 1,
      frameId: 'frame-1',
      boundaryTransformGeneration: 1,
    );
    expect(bad.projectToRaster(), isNull);
  });

  test('outside-boundary points are unavailable rather than clamped', () {
    final coord = buildCaptureCoordinate(
      globalX: -5,
      globalY: 10,
      boundaryOriginX: 0,
      boundaryOriginY: 0,
      boundaryWidth: 100,
      boundaryHeight: 100,
      framePixelWidth: 100,
      framePixelHeight: 100,
      frameId: 'frame-1',
      boundaryTransformGeneration: 1,
    );
    expect(coord.isAvailable, isFalse);
    expect(coord.unavailableReason, 'outside_boundary');
    expect(coord.projectToRaster(), isNull);
  });

  test('missing frame yields unavailable transform', () {
    final coord = buildCaptureCoordinate(
      globalX: 10,
      globalY: 10,
      boundaryOriginX: 0,
      boundaryOriginY: 0,
      boundaryWidth: 100,
      boundaryHeight: 100,
      framePixelWidth: 0,
      framePixelHeight: 0,
      frameId: null,
      boundaryTransformGeneration: 1,
    );
    expect(coord.unavailableReason, 'missing_frame');
  });

  test('golden fixture freezes the consumer contract', () {
    final golden = buildCaptureCoordinate(
      globalX: 45,
      globalY: 95,
      boundaryOriginX: 10,
      boundaryOriginY: 20,
      boundaryWidth: 100,
      boundaryHeight: 200,
      framePixelWidth: 200,
      framePixelHeight: 400,
      frameId: 'frame-golden',
      boundaryTransformGeneration: 7,
    );
    expect(golden.toJson(), {
      'version': 1,
      'sourceSpace': 'boundaryLocalLogical',
      'boundaryOriginX': 10.0,
      'boundaryOriginY': 20.0,
      'boundaryWidth': 100.0,
      'boundaryHeight': 200.0,
      'localX': 35.0,
      'localY': 75.0,
      'normalizedX': 0.35,
      'normalizedY': 0.375,
      'framePixelWidth': 200,
      'framePixelHeight': 400,
      'effectiveScaleX': 2.0,
      'effectiveScaleY': 2.0,
      'frameId': 'frame-golden',
      'boundaryTransformGeneration': 7,
    });
    expect(golden.projectToRaster(), (x: 70, y: 150));
  });

  test(
    'captureCoordinate JSON nests under tap data for collector passthrough',
    () {
      final coord = buildCaptureCoordinate(
        globalX: 50,
        globalY: 50,
        boundaryOriginX: 0,
        boundaryOriginY: 0,
        boundaryWidth: 100,
        boundaryHeight: 100,
        framePixelWidth: 100,
        framePixelHeight: 100,
        frameId: 'frame-1',
        boundaryTransformGeneration: 1,
      );
      final event = TugboatEvent(
        id: 'e1',
        atMs: 1,
        type: 'tap',
        data: {'x': 50.0, 'y': 50.0, 'captureCoordinate': coord.toJson()},
      );
      final encoded =
          jsonDecode(jsonEncode(event.toJson())) as Map<String, Object?>;
      final data = Map<String, Object?>.from(encoded['data']! as Map);
      expect(data['x'], 50.0);
      expect(data['y'], 50.0);
      expect(
        Map<String, Object?>.from(data['captureCoordinate']! as Map),
        coord.toJson(),
      );
    },
  );
}
