part of 'anchors.dart';

/// Per-inventory state for the bounds evidence: `visibleFraction` on each
/// element. Built once per inventory, only when it will be emitted (never on
/// the production tap path), and discarded with it.
///
/// Everything here is geometry. It never reads text, never mutates the tree
/// and never throws: any surprise leaves the optional field out.
class _BoundsEvidence {
  _BoundsEvidence(this.rootRender) : boundary = Offset.zero & rootRender.size;

  final RenderBox rootRender;

  /// The capture boundary in its own coordinates, which is the frame the
  /// element rects are expressed in.
  final Rect boundary;

  /// Accumulated clip of every ancestor of a render object, in boundary
  /// coordinates; a null value means "not clipped". Rows of one list share
  /// their ancestors, so each ancestor chain is walked once.
  final Map<RenderObject, Rect?> _clipAbove = {};

  /// `visibleFraction` for an element whose paint box is [rect] in boundary
  /// coordinates: null when it is fully visible (three-decimal rounding) or
  /// cannot be told, otherwise the rounded share in 0 to 1.
  double? visibleFractionFor(Element element, Rect rect) {
    final render = element.renderObject;
    final area = rect.width * rect.height;
    if (render is! RenderBox || !(area > 0)) return null;
    try {
      var visible = rect.intersect(boundary);
      final clip = _clipAboveOf(render);
      if (clip != null) visible = visible.intersect(clip);
      final fraction = (_rectArea(visible) / area).clamp(0.0, 1.0);
      final rounded = (fraction * 1000).round() / 1000;
      return rounded < 1 ? rounded : null;
    } catch (_) {
      return null;
    }
  }

  double _rectArea(Rect rect) =>
      rect.width <= 0 || rect.height <= 0 ? 0 : rect.width * rect.height;

  /// Intersection of the approximate paint clips of every ancestor of [node]
  /// below the capture boundary, or null when nothing clips it.
  Rect? _clipAboveOf(RenderObject node) {
    final pending = <RenderObject>[];
    RenderObject? cursor = node;
    Rect? clip;
    while (cursor != null && !identical(cursor, rootRender)) {
      if (_clipAbove.containsKey(cursor)) {
        clip = _clipAbove[cursor];
        break;
      }
      pending.add(cursor);
      cursor = cursor.parent;
    }
    // Not below the boundary: nothing known to clip it.
    if (cursor == null) return null;
    for (final child in pending.reversed) {
      clip = _intersectClips(clip, _clipFromParent(child));
      _clipAbove[child] = clip;
    }
    return clip;
  }

  Rect? _intersectClips(Rect? above, Rect? own) {
    if (above == null) return own;
    if (own == null) return above;
    return above.intersect(own);
  }

  /// The clip [child]'s parent applies to it, in boundary coordinates. The
  /// boundary itself is handled by the caller, so its own clip is skipped.
  Rect? _clipFromParent(RenderObject child) {
    final parent = child.parent;
    if (parent == null || identical(parent, rootRender)) return null;
    try {
      final clip = parent.describeApproximatePaintClip(child);
      if (clip == null) return null;
      return MatrixUtils.transformRect(parent.getTransformTo(rootRender), clip);
    } catch (_) {
      return null;
    }
  }
}

extension TugboatBoundsEvidenceApi on AnchorResolver {
  /// The frame `boundsNorm` is measured in. Null when the boundary is not
  /// laid out or has no [FlutterView]. Never throws.
  TugboatInventoryViewport? _viewportFor(RenderBox rootRender) {
    try {
      final view = _renderViewOf(rootRender)?.flutterView;
      if (view == null || !rootRender.hasSize) return null;
      final ratio = view.devicePixelRatio;
      if (!(ratio > 0)) return null;
      final origin = rootRender.localToGlobal(Offset.zero);
      final padding = view.viewPadding;
      return TugboatInventoryViewport(
        widthPx: rootRender.size.width,
        heightPx: rootRender.size.height,
        devicePixelRatio: ratio,
        boundaryLeft: origin.dx,
        boundaryTop: origin.dy,
        insets: TugboatViewportInsets(
          top: padding.top / ratio,
          bottom: padding.bottom / ratio,
          left: padding.left / ratio,
          right: padding.right / ratio,
        ),
        keyboardInset: view.viewInsets.bottom / ratio,
      );
    } catch (_) {
      return null;
    }
  }

  /// The render view the boundary paints into, found through the render tree
  /// so no inherited-widget dependency is registered on the host's elements.
  RenderView? _renderViewOf(RenderBox rootRender) {
    RenderObject? node = rootRender;
    while (node != null && node is! RenderView) {
      node = node.parent;
    }
    return node is RenderView ? node : null;
  }

  /// The primary vertical scrollable of the inventory's tree: the retained
  /// vertical [Scrollable] whose viewport shows the largest area inside the
  /// capture boundary; the earliest in tree order wins a tie. Scrollables
  /// inside an [EditableText] (multi-line fields) never count. Null when there
  /// is none. Never throws.
  TugboatInventoryScroll? _primaryScrollFor(
    _TokenMap tokenMap,
    RenderBox rootRender,
  ) {
    try {
      ScrollPosition? best;
      var bestArea = 0.0;
      for (final element in tokenMap.tokens.keys) {
        if (element.widget is! Scrollable) continue;
        final candidate = _scrollCandidate(element, rootRender);
        if (candidate == null || candidate.area <= bestArea) continue;
        best = candidate.position;
        bestArea = candidate.area;
      }
      return best == null ? null : _scrollOf(best);
    } catch (_) {
      return null;
    }
  }

  ({ScrollPosition position, double area})? _scrollCandidate(
    Element element,
    RenderBox rootRender,
  ) {
    final state = element is StatefulElement ? element.state : null;
    if (state is! ScrollableState || !_isFreeScrollable(element)) return null;
    final position = state.position;
    if (position.axis != Axis.vertical || !position.hasPixels) return null;
    final rect = _paintRectInRoot(element, rootRender);
    if (rect == null) return null;
    final shown = rect.intersect(Offset.zero & rootRender.size);
    if (shown.width <= 0 || shown.height <= 0) return null;
    return (position: position, area: shown.width * shown.height);
  }

  bool _isFreeScrollable(Element element) =>
      element.findAncestorWidgetOfExactType<EditableText>() == null;

  TugboatInventoryScroll? _scrollOf(ScrollPosition position) {
    final offset = position.pixels;
    if (!offset.isFinite) return null;
    final extent = position.hasContentDimensions
        ? position.maxScrollExtent
        : null;
    return TugboatInventoryScroll(
      offsetPx: offset,
      maxExtentPx: extent != null && extent.isFinite ? extent : null,
    );
  }
}
