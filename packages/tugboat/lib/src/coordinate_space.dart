/// Versioned capture-boundary coordinate contract (U12).
///
/// Legacy tap payloads keep global logical `x`/`y`. Canonical playback uses
/// [TugboatCaptureCoordinate] bound to a compatible before-frame transform.
///
/// Projection rule (one output pixel):
///   pixelX = round(normalizedX * (framePixelWidth - 1))
///   pixelY = round(normalizedY * (framePixelHeight - 1))
/// when width/height > 1; otherwise pixel = 0.
///
/// Outside-boundary, missing-frame, and generation-mismatch transforms are
/// serialized as [TugboatCaptureCoordinate.unavailable] — never clamped.
library;

/// Schema version for [TugboatCaptureCoordinate.toJson].
const int tugboatCaptureCoordinateVersion = 1;

/// Source space for a sampled pointer relative to the capture boundary.
enum TugboatCoordinateSourceSpace {
  /// Flutter global logical coordinates (same as legacy `x`/`y`).
  globalLogical,

  /// Logical coordinates local to the active [TugboatCaptureBoundary].
  boundaryLocalLogical,
}

/// Immutable transform that projects a pointer onto its referenced frame.
class TugboatCaptureCoordinate {
  const TugboatCaptureCoordinate({
    required this.sourceSpace,
    required this.boundaryOriginX,
    required this.boundaryOriginY,
    required this.boundaryWidth,
    required this.boundaryHeight,
    required this.localX,
    required this.localY,
    required this.normalizedX,
    required this.normalizedY,
    required this.framePixelWidth,
    required this.framePixelHeight,
    required this.effectiveScaleX,
    required this.effectiveScaleY,
    required this.frameId,
    required this.boundaryTransformGeneration,
    this.unavailableReason,
  }) : version = tugboatCaptureCoordinateVersion;

  /// Constructs an unavailable coordinate with a bounded reason.
  const TugboatCaptureCoordinate.unavailable({
    required this.unavailableReason,
    this.sourceSpace = TugboatCoordinateSourceSpace.globalLogical,
    this.boundaryOriginX = 0,
    this.boundaryOriginY = 0,
    this.boundaryWidth = 0,
    this.boundaryHeight = 0,
    this.localX = 0,
    this.localY = 0,
    this.normalizedX = 0,
    this.normalizedY = 0,
    this.framePixelWidth = 0,
    this.framePixelHeight = 0,
    this.effectiveScaleX = 0,
    this.effectiveScaleY = 0,
    this.frameId,
    this.boundaryTransformGeneration = 0,
  }) : version = tugboatCaptureCoordinateVersion;

  final int version;
  final TugboatCoordinateSourceSpace sourceSpace;
  final double boundaryOriginX;
  final double boundaryOriginY;
  final double boundaryWidth;
  final double boundaryHeight;
  final double localX;
  final double localY;
  final double normalizedX;
  final double normalizedY;
  final int framePixelWidth;
  final int framePixelHeight;
  final double effectiveScaleX;
  final double effectiveScaleY;
  final String? frameId;
  final int boundaryTransformGeneration;
  final String? unavailableReason;

  bool get isAvailable => unavailableReason == null;

  /// Projects [normalizedX]/[normalizedY] to raster pixels using the documented
  /// rounding rule. Returns null when unavailable or dimensions are invalid.
  ({int x, int y})? projectToRaster() {
    if (!isAvailable || framePixelWidth <= 0 || framePixelHeight <= 0) {
      return null;
    }
    if (normalizedX < 0 ||
        normalizedX > 1 ||
        normalizedY < 0 ||
        normalizedY > 1) {
      return null;
    }
    final x = framePixelWidth <= 1
        ? 0
        : (normalizedX * (framePixelWidth - 1)).round();
    final y = framePixelHeight <= 1
        ? 0
        : (normalizedY * (framePixelHeight - 1)).round();
    return (x: x, y: y);
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'sourceSpace': sourceSpace.name,
    'boundaryOriginX': boundaryOriginX,
    'boundaryOriginY': boundaryOriginY,
    'boundaryWidth': boundaryWidth,
    'boundaryHeight': boundaryHeight,
    'localX': localX,
    'localY': localY,
    'normalizedX': normalizedX,
    'normalizedY': normalizedY,
    'framePixelWidth': framePixelWidth,
    'framePixelHeight': framePixelHeight,
    'effectiveScaleX': effectiveScaleX,
    'effectiveScaleY': effectiveScaleY,
    if (frameId != null) 'frameId': frameId,
    'boundaryTransformGeneration': boundaryTransformGeneration,
    if (unavailableReason != null) 'unavailableReason': unavailableReason,
  };

  factory TugboatCaptureCoordinate.fromJson(Map<String, Object?> json) {
    final reason = json['unavailableReason'] as String?;
    final source = _coordinateSourceFromJson(json);
    if (reason != null) {
      return _unavailableCoordinateFromJson(json, reason, source);
    }
    return _availableCoordinateFromJson(json, source);
  }
}

TugboatCoordinateSourceSpace _coordinateSourceFromJson(
  Map<String, Object?> json,
) {
  final sourceName = json['sourceSpace'] as String? ?? 'globalLogical';
  return TugboatCoordinateSourceSpace.values.firstWhere(
    (value) => value.name == sourceName,
    orElse: () => TugboatCoordinateSourceSpace.globalLogical,
  );
}

TugboatCaptureCoordinate _unavailableCoordinateFromJson(
  Map<String, Object?> json,
  String reason,
  TugboatCoordinateSourceSpace source,
) => TugboatCaptureCoordinate.unavailable(
  unavailableReason: reason,
  sourceSpace: source,
  boundaryOriginX: _jsonDoubleOrZero(json, 'boundaryOriginX'),
  boundaryOriginY: _jsonDoubleOrZero(json, 'boundaryOriginY'),
  boundaryWidth: _jsonDoubleOrZero(json, 'boundaryWidth'),
  boundaryHeight: _jsonDoubleOrZero(json, 'boundaryHeight'),
  localX: _jsonDoubleOrZero(json, 'localX'),
  localY: _jsonDoubleOrZero(json, 'localY'),
  normalizedX: _jsonDoubleOrZero(json, 'normalizedX'),
  normalizedY: _jsonDoubleOrZero(json, 'normalizedY'),
  framePixelWidth: _jsonIntOrZero(json, 'framePixelWidth'),
  framePixelHeight: _jsonIntOrZero(json, 'framePixelHeight'),
  effectiveScaleX: _jsonDoubleOrZero(json, 'effectiveScaleX'),
  effectiveScaleY: _jsonDoubleOrZero(json, 'effectiveScaleY'),
  frameId: json['frameId'] as String?,
  boundaryTransformGeneration: _jsonIntOrZero(
    json,
    'boundaryTransformGeneration',
  ),
);

TugboatCaptureCoordinate _availableCoordinateFromJson(
  Map<String, Object?> json,
  TugboatCoordinateSourceSpace source,
) => TugboatCaptureCoordinate(
  sourceSpace: source,
  boundaryOriginX: (json['boundaryOriginX'] as num).toDouble(),
  boundaryOriginY: (json['boundaryOriginY'] as num).toDouble(),
  boundaryWidth: (json['boundaryWidth'] as num).toDouble(),
  boundaryHeight: (json['boundaryHeight'] as num).toDouble(),
  localX: (json['localX'] as num).toDouble(),
  localY: (json['localY'] as num).toDouble(),
  normalizedX: (json['normalizedX'] as num).toDouble(),
  normalizedY: (json['normalizedY'] as num).toDouble(),
  framePixelWidth: (json['framePixelWidth'] as num).toInt(),
  framePixelHeight: (json['framePixelHeight'] as num).toInt(),
  effectiveScaleX: (json['effectiveScaleX'] as num).toDouble(),
  effectiveScaleY: (json['effectiveScaleY'] as num).toDouble(),
  frameId: json['frameId'] as String?,
  boundaryTransformGeneration: (json['boundaryTransformGeneration'] as num)
      .toInt(),
);

double _jsonDoubleOrZero(Map<String, Object?> json, String key) =>
    (json[key] as num?)?.toDouble() ?? 0;

int _jsonIntOrZero(Map<String, Object?> json, String key) =>
    (json[key] as num?)?.toInt() ?? 0;

/// Builds a capture coordinate from boundary geometry and frame raster size.
///
/// Returns an unavailable coordinate when the point is outside the boundary
/// or frame dimensions are missing.
TugboatCaptureCoordinate buildCaptureCoordinate({
  required double globalX,
  required double globalY,
  required double boundaryOriginX,
  required double boundaryOriginY,
  required double boundaryWidth,
  required double boundaryHeight,
  required int framePixelWidth,
  required int framePixelHeight,
  required String? frameId,
  required int boundaryTransformGeneration,
}) {
  if (boundaryWidth <= 0 || boundaryHeight <= 0) {
    return const TugboatCaptureCoordinate.unavailable(
      unavailableReason: 'invalid_boundary',
    );
  }
  return _buildCoordinateForUsableBoundary(
    globalX: globalX,
    globalY: globalY,
    boundaryOriginX: boundaryOriginX,
    boundaryOriginY: boundaryOriginY,
    boundaryWidth: boundaryWidth,
    boundaryHeight: boundaryHeight,
    framePixelWidth: framePixelWidth,
    framePixelHeight: framePixelHeight,
    frameId: frameId,
    boundaryTransformGeneration: boundaryTransformGeneration,
  );
}

TugboatCaptureCoordinate _buildCoordinateForUsableBoundary({
  required double globalX,
  required double globalY,
  required double boundaryOriginX,
  required double boundaryOriginY,
  required double boundaryWidth,
  required double boundaryHeight,
  required int framePixelWidth,
  required int framePixelHeight,
  required String? frameId,
  required int boundaryTransformGeneration,
}) {
  if (framePixelWidth <= 0 || framePixelHeight <= 0 || frameId == null) {
    return _missingFrameCoordinate(
      globalX,
      globalY,
      boundaryOriginX,
      boundaryOriginY,
      boundaryWidth,
      boundaryHeight,
      boundaryTransformGeneration,
    );
  }
  return _availableFrameCoordinate(
    globalX,
    globalY,
    boundaryOriginX,
    boundaryOriginY,
    boundaryWidth,
    boundaryHeight,
    framePixelWidth,
    framePixelHeight,
    frameId,
    boundaryTransformGeneration,
  );
}

TugboatCaptureCoordinate _availableFrameCoordinate(
  double globalX,
  double globalY,
  double boundaryOriginX,
  double boundaryOriginY,
  double boundaryWidth,
  double boundaryHeight,
  int framePixelWidth,
  int framePixelHeight,
  String frameId,
  int boundaryTransformGeneration,
) {
  final localX = globalX - boundaryOriginX;
  final localY = globalY - boundaryOriginY;
  if (localX < 0 ||
      localY < 0 ||
      localX > boundaryWidth ||
      localY > boundaryHeight) {
    return TugboatCaptureCoordinate.unavailable(
      unavailableReason: 'outside_boundary',
      boundaryOriginX: boundaryOriginX,
      boundaryOriginY: boundaryOriginY,
      boundaryWidth: boundaryWidth,
      boundaryHeight: boundaryHeight,
      localX: localX,
      localY: localY,
      framePixelWidth: framePixelWidth,
      framePixelHeight: framePixelHeight,
      frameId: frameId,
      boundaryTransformGeneration: boundaryTransformGeneration,
    );
  }

  final normalizedX = (localX / boundaryWidth).clamp(0.0, 1.0);
  final normalizedY = (localY / boundaryHeight).clamp(0.0, 1.0);
  final effectiveScaleX = framePixelWidth / boundaryWidth;
  final effectiveScaleY = framePixelHeight / boundaryHeight;

  return TugboatCaptureCoordinate(
    sourceSpace: TugboatCoordinateSourceSpace.boundaryLocalLogical,
    boundaryOriginX: boundaryOriginX,
    boundaryOriginY: boundaryOriginY,
    boundaryWidth: boundaryWidth,
    boundaryHeight: boundaryHeight,
    localX: localX,
    localY: localY,
    normalizedX: normalizedX,
    normalizedY: normalizedY,
    framePixelWidth: framePixelWidth,
    framePixelHeight: framePixelHeight,
    effectiveScaleX: effectiveScaleX,
    effectiveScaleY: effectiveScaleY,
    frameId: frameId,
    boundaryTransformGeneration: boundaryTransformGeneration,
  );
}

TugboatCaptureCoordinate _missingFrameCoordinate(
  double globalX,
  double globalY,
  double boundaryOriginX,
  double boundaryOriginY,
  double boundaryWidth,
  double boundaryHeight,
  int boundaryTransformGeneration,
) {
  final localX = globalX - boundaryOriginX;
  final localY = globalY - boundaryOriginY;
  if (_isOutsideBoundary(localX, localY, boundaryWidth, boundaryHeight)) {
    return TugboatCaptureCoordinate.unavailable(
      unavailableReason: 'outside_boundary',
      sourceSpace: TugboatCoordinateSourceSpace.boundaryLocalLogical,
      boundaryOriginX: boundaryOriginX,
      boundaryOriginY: boundaryOriginY,
      boundaryWidth: boundaryWidth,
      boundaryHeight: boundaryHeight,
      localX: localX,
      localY: localY,
      boundaryTransformGeneration: boundaryTransformGeneration,
    );
  }
  return TugboatCaptureCoordinate.unavailable(
    unavailableReason: 'missing_frame',
    sourceSpace: TugboatCoordinateSourceSpace.boundaryLocalLogical,
    boundaryOriginX: boundaryOriginX,
    boundaryOriginY: boundaryOriginY,
    boundaryWidth: boundaryWidth,
    boundaryHeight: boundaryHeight,
    localX: localX,
    localY: localY,
    normalizedX: (localX / boundaryWidth).clamp(0.0, 1.0),
    normalizedY: (localY / boundaryHeight).clamp(0.0, 1.0),
    boundaryTransformGeneration: boundaryTransformGeneration,
  );
}

bool _isOutsideBoundary(double x, double y, double width, double height) =>
    x < 0 || y < 0 || x > width || y > height;
