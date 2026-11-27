part of 'anchors.dart';

/// The screenshot mask walk: one pass over the element tree that decides which
/// render boxes are handed to the pixel masker.
///
/// It is deliberately separate from the identity walk ([_TokenMapVisitor]).
/// Identity prunes whatever is not part of a screen's structure (excluded
/// semantics, content shadowed by a modal route, SDK-owned UI). Pixels are the
/// opposite: anything painted can leak, so this walk prunes only subtrees that
/// are not painted at all:
///
/// * `Offstage(offstage: true)`, `Visibility(visible: false)` and opacity 0
///   (see [tugboatHidesSubtree] and [tugboatHidesRenderObject]);
/// * overlay entries below an opaque route, by visiting the overlay's onstage
///   children. `BlockSemantics` is a semantics concept and is not consulted: a
///   dialog, bottom sheet or menu leaves the screen under it fully painted.
///
/// It never prunes on `ExcludeSemantics`, [TugboatInternal], size or position.
/// A zero-sized or offscreen parent that does not clip still paints its
/// children, so only a node's own rect is dropped (see [_addMaskRect]).
///
/// Marks ([TugboatSensitive]) and the actionable flag propagate from the
/// element's own widget, so a mark directly above an excluded subtree is
/// honoured. Anything that prevents a mask from being computed throws; the
/// capturer turns that into `ScreenshotCaptureFailure.maskFailed` so no
/// unmasked frame is sent.
class _MaskWalk {
  _MaskWalk(this.rootRender, this.shouldMask);

  final RenderBox rootRender;
  final bool Function(Element, Widget, RenderBox, bool, bool) shouldMask;
  final masks = <Rect>[];
  final _maskedRenderObjects = <RenderObject>{};

  void run(Element root) {
    _visit(root, null, false, false, isRoot: true);
  }

  void _visit(
    Element element,
    Element? parent,
    bool sensitive,
    bool underActionable, {
    bool isRoot = false,
  }) {
    final widget = element.widget;
    if (!isRoot && _notPainted(element, widget)) return;
    _addMaskRect(element, widget, sensitive, underActionable);
    final childSensitive = sensitive || widget is TugboatSensitive;
    final childActionable =
        underActionable || tugboatIsActionableWidget(widget);
    void visitChild(Element child) =>
        _visit(child, element, childSensitive, childActionable);
    if (_isOverlayTheater(element, parent)) {
      element.debugVisitOnstageChildren(visitChild);
    } else {
      element.visitChildElements(visitChild);
    }
  }

  /// Only the element's own widget or render object counts: a component
  /// element's `renderObject` is its first descendant's, which says nothing
  /// about the element itself.
  bool _notPainted(Element element, Widget widget) =>
      tugboatHidesSubtree(widget) ||
      (element is RenderObjectElement &&
          tugboatHidesRenderObject(element.renderObject));

  /// The theater under an [Overlay] keeps entries below an opaque route as
  /// offstage children. Its onstage visit skips exactly those.
  bool _isOverlayTheater(Element element, Element? parent) =>
      element is MultiChildRenderObjectElement &&
      parent is StatefulElement &&
      parent.state is OverlayState;

  void _addMaskRect(
    Element element,
    Widget widget,
    bool sensitive,
    bool underActionable,
  ) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return;
    }
    final actionable = underActionable || tugboatIsActionableWidget(widget);
    if (!shouldMask(element, widget, renderObject, sensitive, actionable)) {
      return;
    }
    if (!_maskedRenderObjects.add(renderObject)) return;
    // Throws when the transform cannot be computed: an element that must be
    // masked and cannot be placed fails the capture.
    final rect = MatrixUtils.transformRect(
      renderObject.getTransformTo(rootRender),
      renderObject.paintBounds,
    ).intersect(rootRender.paintBounds);
    if (rect.width > 0 && rect.height > 0) masks.add(rect);
  }
}
