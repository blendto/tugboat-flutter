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

  /// Subtree paint signature for this boundary, including nested
  /// [RepaintBoundary] retained layers. Prefer this over [paintGeneration]
  /// alone when deciding whether a capture would observe new pixels.
  int get subtreePaintSignature => tugboatSubtreePaintSignature(this);

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _paintGeneration++;
  }
}

/// Paint-activity signature for [root] and every descendant [RenderRepaintBoundary].
///
/// Nested repaint boundaries can rasterize without invoking [root]'s [paint],
/// so an outer paint-generation counter alone cannot decide whether a capture
/// would observe new pixels. This mixes:
/// - outer [TugboatCaptureRenderBoundary.paintGeneration] when present;
/// - render-object identity for each nested boundary;
/// - retained [PictureLayer] picture identity under each boundary, which
///   changes when that boundary paints.
int tugboatSubtreePaintSignature(RenderObject root) {
  var signature = 0;

  void visitLayer(Layer? layer) {
    if (layer == null) {
      return;
    }
    signature = Object.hash(signature, identityHashCode(layer));
    if (layer is PictureLayer) {
      signature = Object.hash(signature, identityHashCode(layer.picture));
    }
    if (layer is TransformLayer) {
      final matrix = layer.transform;
      if (matrix != null) {
        signature = Object.hash(signature, matrix.storage.hashCode);
      }
    }
    if (layer is OpacityLayer) {
      signature = Object.hash(signature, layer.alpha);
    }
    if (layer is OffsetLayer) {
      signature = Object.hash(signature, layer.offset.dx, layer.offset.dy);
    }
    if (layer is ContainerLayer) {
      var child = layer.firstChild;
      while (child != null) {
        visitLayer(child);
        child = child.nextSibling;
      }
    }
  }

  void visit(RenderObject node) {
    if (node is RenderRepaintBoundary) {
      signature = Object.hash(signature, identityHashCode(node));
      if (node is TugboatCaptureRenderBoundary) {
        signature = Object.hash(signature, node.paintGeneration);
      }
      // RenderObject.layer is protected; nested-boundary paint detection needs
      // the retained layer tree under each RepaintBoundary.
      // ignore: invalid_use_of_protected_member
      visitLayer(node.layer);
    }
    node.visitChildren(visit);
  }

  visit(root);
  return signature;
}
