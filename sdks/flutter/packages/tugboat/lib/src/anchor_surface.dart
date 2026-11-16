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

/// Private framework widgets that sit between the host plumbing and the
/// builder's result. Any other private widget there may be the app's own
/// (a private sheet class never reaches the canonical path), so it ends the
/// search instead of letting a deeper framework or app widget be named.
const _surfacePlumbingWidgets = <String>{
  '_MaterialInterior',
  '_ShapeBorderPaint',
  '_InkFeatures',
  '_CaptureAll',
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
        widgetClass = _surfaceWidgetClass(tokenMap);
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
  /// widget all mean the builder is not an app widget class we can name.
  String? _surfaceWidgetClass(_TokenMap tokenMap) {
    // Without a blocking overlay the tokens are not scoped to the surface.
    if (!tokenMap.hasBlockingOverlay) return null;
    final children = _retainedChildren(tokenMap);
    var node = _soleSurfaceRoot(tokenMap);
    while (node != null) {
      final name = _tokenTypeName(tokenMap.tokens[node]);
      if (name == null) return null;
      if (!_surfaceHostWidgets.contains(name)) {
        return _isAppWidgetCandidate(node, name, tokenMap) ? name : null;
      }
      final below = children[node];
      node = below != null && below.length == 1 ? below.single : null;
    }
    return null;
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
  Element? _soleSurfaceRoot(_TokenMap tokenMap) {
    final roots =
        [
          for (final entry in tokenMap.retainedParents.entries)
            if (entry.value == null &&
                tokenMap.tokens.containsKey(entry.key) &&
                !tokenMap.newRoleCandidates.contains(entry.key))
              entry.key,
        ].where((root) {
          final name = _tokenTypeName(tokenMap.tokens[root]);
          return !_surfaceBarrierRoots.contains(name);
        }).toList();
    if (roots.length == 1) return roots.single;
    final hosts = roots.where(
      (root) =>
          _surfaceHostWidgets.contains(_tokenTypeName(tokenMap.tokens[root])),
    );
    return hosts.length == 1 ? hosts.single : null;
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
  /// between [element] and its retained parent [host].
  bool _hasUnknownPrivateAbove(Element element, Element? host) {
    var unknown = false;
    element.visitAncestorElements((ancestor) {
      if (identical(ancestor, host)) return false;
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
