part of 'anchors.dart';

/// Framework widgets that sit between an overlay route's root and the widget
/// the app's builder returned, and carry no identity of their own.
const _surfaceHostWidgets = <String>{
  'DisplayFeatureSubScreen',
  'BottomSheet',
  'RawGestureDetector',
  'CupertinoUserInterfaceLevel',
  'CustomSingleChildLayout',
};

/// Roots that belong to the overlay but not to the surface's own content.
const _surfaceBarrierRoots = <String>{'ModalBarrier', 'AnimatedModalBarrier'};

/// A framework `Dialog` has one `child` slot. When its one retained child is
/// an app widget class (`Dialog.fullscreen(child: CouponDialog())`), that
/// class is the dialog's content; anything else still fails closed.
const _surfaceDialogContainer = 'Dialog';

/// Private framework widgets that sit between the host plumbing and the
/// builder's result. Any other private widget there may be the app's own
/// (a private sheet class never reaches the canonical path), so it ends the
/// search instead of letting a deeper framework or app widget be named.
const _surfacePlumbingWidgets = <String>{
  '_MaterialInterior',
  '_ShapeBorderPaint',
  '_InkFeatures',
  '_CaptureAll',
  // Between a Scaffold and its body; reached only through a popup route's
  // own Scaffold (see _isSurfaceContainer).
  '_BodyBuilder',
};

/// Framework widgets an app's builder commonly returns directly. Reaching one
/// of these first means the builder is inline, so there is no app class.
const _surfaceFrameworkContent = <String>{
  'AlertDialog',
  'SimpleDialog',
  'Dialog',
  'CupertinoAlertDialog',
  'CupertinoActionSheet',
  'CupertinoPopupSurface',
  'DraggableScrollableSheet',
  'Scaffold',
  'Card',
  'ListTile',
  'ListView',
  'GridView',
  'SingleChildScrollView',
  'Scrollable',
  'Scrollbar',
  'CupertinoScrollbar',
  'Form',
  'TextField',
  'TextFormField',
  'Text',
  'Icon',
  'Image',
  'Divider',
};

extension TugboatSurfaceApi on AnchorResolver {
  /// The surface an inventory built from [tokenMap] describes.
  ///
  /// [kind] is the [TugboatSurfaceKind] of the current route (page when the
  /// route is not known). Never throws: a failed tree walk just leaves
  /// `widgetClass` out.
  TugboatSurface _surfaceFor(_TokenMap tokenMap, {required String? kind}) {
    final resolved = kind ?? TugboatSurfaceKind.page;
    String? widgetClass;
    try {
      if (_surfaceHasHostChain(resolved)) {
        widgetClass = _surfaceWidgetClass(tokenMap, resolved);
      }
    } catch (_) {
      // A detached or racing element tree only costs the optional field.
    }
    return TugboatSurface(kind: resolved, widgetClass: widgetClass);
  }

  /// Sheets, dialogs and popups are the surfaces whose retained tree is
  /// scoped to the route's own overlay. Pages share the tree with shell
  /// widgets around a nested navigator, and menus are built by the framework.
  bool _surfaceHasHostChain(String kind) =>
      kind == TugboatSurfaceKind.sheet ||
      kind == TugboatSurfaceKind.dialog ||
      kind == TugboatSurfaceKind.popup;

  /// The first retained widget below the overlay host that is neither host
  /// plumbing nor framework content, or null when the chain is ambiguous.
  ///
  /// Fails closed: more than one root or a fork in the host chain, an
  /// actionable, list-item or non-composite widget, or a framework content
  /// widget all mean the builder is not an app widget class we can name. A
  /// `Dialog`, and a popup route's own `Scaffold`, are looked through only
  /// when their one retained child is the next link.
  String? _surfaceWidgetClass(_TokenMap tokenMap, String kind) {
    // Without a blocking overlay the tokens are not scoped to the surface.
    if (!tokenMap.hasBlockingOverlay) return null;
    final children = _retainedChildren(tokenMap);
    var node = _soleSurfaceRoot(tokenMap);
    while (node != null) {
      final name = _tokenTypeName(tokenMap.tokens[node]);
      if (name == null) return null;
      final below = _soleChild(children[node]);
      final passThrough =
          _surfaceHostWidgets.contains(name) ||
          _isSurfaceContainer(node, name, kind, below);
      if (!passThrough) {
        return _isAppWidgetCandidate(node, name, tokenMap) ? name : null;
      }
      node = below;
    }
    return null;
  }

  Element? _soleChild(List<Element>? children) =>
      children != null && children.length == 1 ? children.single : null;

  /// A framework container whose single retained [child] is the surface's
  /// content: a `Dialog`, or the `Scaffold` a custom popup route builds
  /// around its builder (`Scaffold(body: builder(context))`), when [child]
  /// sits in the body slot. Sheets and dialogs that return a `Scaffold` are
  /// not looked through, so their route keys do not move.
  bool _isSurfaceContainer(
    Element node,
    String name,
    String kind,
    Element? child,
  ) {
    if (child == null) return false;
    if (name == _surfaceDialogContainer) return true;
    return name == 'Scaffold' &&
        kind == TugboatSurfaceKind.popup &&
        _isScaffoldBody(child, node);
  }

  /// Whether [child] is laid out in [scaffold]'s body slot.
  bool _isScaffoldBody(Element child, Element scaffold) {
    var body = false;
    child.visitAncestorElements((ancestor) {
      if (identical(ancestor, scaffold)) return false;
      final widget = ancestor.widget;
      if (widget is LayoutId) {
        final id = widget.id;
        body = id is Enum && id.name == 'body';
        return false;
      }
      return true;
    });
    return body;
  }

  /// Retained children of each token. Low-level roles (a framework tap
  /// Semantics on a sheet's drag handle) are chrome, not app content, so they
  /// do not count towards the single-child host chain.
  Map<Element, List<Element>> _retainedChildren(_TokenMap tokenMap) {
    final children = <Element, List<Element>>{};
    tokenMap.retainedParents.forEach((element, parent) {
      if (parent != null &&
          tokenMap.tokens.containsKey(element) &&
          !tokenMap.newRoleCandidates.contains(element)) {
        (children[parent] ??= <Element>[]).add(element);
      }
    });
    return children;
  }

  /// The one retained root of the surface. When transient overlay entries
  /// add roots of their own (a text selection toolbar and its handles above a
  /// focused field), the one overlay host root among them is the surface, so
  /// a sheet or dialog keeps its class, and its `sheet:`/`dialog:` route key,
  /// while they show.
  ///
  /// A root is a token with no retained parent left in the map. An app widget
  /// between the capture root and the `Navigator` (a provider host, an
  /// overlay host) is retained, then shadowed by the modal barrier, so the
  /// surface's root still points at it. Roots in different overlays mean
  /// shell content beside a nested navigator (a bottom bar), so the surface
  /// is not named.
  Element? _soleSurfaceRoot(_TokenMap tokenMap) {
    final roots = _surfaceRoots(tokenMap);
    if (roots.isEmpty) return null;
    if (roots.length == 1) return roots.single;
    final overlay = _overlayOf(roots.first);
    if (overlay == null ||
        roots.any((root) => !identical(_overlayOf(root), overlay))) {
      return null;
    }
    final hosts = roots.where(
      (root) =>
          _surfaceHostWidgets.contains(_tokenTypeName(tokenMap.tokens[root])),
    );
    return hosts.length == 1 ? hosts.single : null;
  }

  List<Element> _surfaceRoots(_TokenMap tokenMap) => [
    for (final entry in tokenMap.retainedParents.entries)
      if (_isRetainedRoot(entry.key, entry.value, tokenMap) &&
          !_surfaceBarrierRoots.contains(
            _tokenTypeName(tokenMap.tokens[entry.key]),
          ))
        entry.key,
  ];

  bool _isRetainedRoot(Element element, Element? parent, _TokenMap tokenMap) =>
      tokenMap.tokens.containsKey(element) &&
      !tokenMap.newRoleCandidates.contains(element) &&
      (parent == null || !tokenMap.tokens.containsKey(parent));

  /// The nearest `Overlay` above [element], or null outside every overlay.
  Element? _overlayOf(Element element) {
    Element? overlay;
    element.visitAncestorElements((ancestor) {
      if (ancestor is StatefulElement && ancestor.state is OverlayState) {
        overlay = ancestor;
      }
      return overlay == null;
    });
    return overlay;
  }

  /// `PubSheet#0` -> `PubSheet`; null for list-item tokens (`[item:3]`).
  String? _tokenTypeName(String? token) {
    if (token == null) return null;
    final ordinal = token.lastIndexOf('#');
    return ordinal <= 0 ? null : token.substring(0, ordinal);
  }

  bool _isAppWidgetCandidate(Element element, String name, _TokenMap tokenMap) {
    if (_surfaceFrameworkContent.contains(name)) return false;
    if (element is! StatelessElement && element is! StatefulElement) {
      return false;
    }
    if (tokenMap.isActionable[element] == true) return false;
    if (tugboatRoleForWidget(element.widget) != null) return false;
    return !_hasUnknownPrivateAbove(element, tokenMap.retainedParents[element]);
  }

  /// Whether a private widget other than known framework plumbing sits
  /// between [element] and its retained parent [host]. Under a `Scaffold`
  /// (a popup route's own) the walk ends at the body slot's `LayoutId`: the
  /// Scaffold's own private scopes are above it.
  bool _hasUnknownPrivateAbove(Element element, Element? host) {
    final scaffoldHost = host?.widget is Scaffold;
    var unknown = false;
    element.visitAncestorElements((ancestor) {
      if (identical(ancestor, host)) return false;
      if (scaffoldHost && ancestor.widget is LayoutId) return false;
      final name = _widgetTypeBase(ancestor.widget);
      unknown = name.startsWith('_') && !_surfacePlumbingWidgets.contains(name);
      return !unknown;
    });
    return unknown;
  }

  String _widgetTypeBase(Widget widget) {
    final name = widget.runtimeType.toString();
    final generic = name.indexOf('<');
    return generic == -1 ? name : name.substring(0, generic);
  }
}
