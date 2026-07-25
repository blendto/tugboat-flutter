import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Repaint boundary used by Tugboat to prove that a fresh capture request
/// observed a paint completed after the request was admitted.
///
/// This is internal SDK plumbing. The public wrapping API remains unchanged.
class TugboatCaptureBoundary extends SingleChildRenderObjectWidget {
  const TugboatCaptureBoundary({super.key, super.child});

  @override
  TugboatCaptureRenderBoundary createRenderObject(BuildContext context) =>
      TugboatCaptureRenderBoundary();
}

class TugboatCaptureRenderBoundary extends RenderRepaintBoundary {
  int _paintGeneration = 0;

  int get paintGeneration => _paintGeneration;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _paintGeneration++;
  }
}
