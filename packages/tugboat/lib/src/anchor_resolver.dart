part of 'anchors.dart';

class _TokenMap {
  _TokenMap({
    required this.tokens,
    required this.retainedParents,
    required this.tagIds,
    required this.labelAnnotations,
    required this.hasBareItem,
    required this.isActionable,
    required this.structuralRouteSignature,
    required this.renderElements,
    required this.hasBlockingOverlay,
    required this.includedElements,
    required this.actionableSummary,
    required this.subLabel,
  });

  final Map<Element, String> tokens;
  final Map<Element, Element?> retainedParents;
  final Map<Element, String> tagIds;
  final Map<Element, String> labelAnnotations;
  final Map<Element, bool> hasBareItem;
  final Map<Element, bool> isActionable;
  final String structuralRouteSignature;
  final Map<RenderObject, Element> renderElements;
  final bool hasBlockingOverlay;
  final Set<Element> includedElements;
  final Map<String, int> actionableSummary;
  final String? subLabel;
}

class _IncludedElements {
  const _IncludedElements({
    this.elements = const {},
    this.pendingBlocker = false,
    this.hasBlockingOverlay = false,
  });

  final Set<Element> elements;
  final bool pendingBlocker;
  final bool hasBlockingOverlay;
}

/// Builds target anchors from hit-test results.
class AnchorResolver {
  AnchorResolver({required this.rootKey, this.widgetNames = const {}});

  final GlobalKey rootKey;
  final Map<Type, String> widgetNames;

  TugboatTargetAnchor? targetAt(Offset globalPosition, {String? route}) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootRender is! RenderBox || rootContext is! Element) return null;

    final tokenMap = _buildTokenMap(rootContext, rootRender);
    return _targetAtWithTokenMap(
      globalPosition,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
    );
  }

  /// Builds inventory and resolves a tap target from one token-map walk.
  ({TugboatSceneInventory? inventory, TugboatTargetAnchor? target})
  buildTapContext({
    required Offset tapPosition,
    required String? route,
    required bool keyboardOpen,
    required bool modalOpen,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootRender is! RenderBox || rootContext is! Element) {
      return (inventory: null, target: null);
    }

    final tokenMap = _buildTokenMap(rootContext, rootRender);
    final stateAnchor = _stateAnchorFromTokenMap(
      tokenMap: tokenMap,
      route: route,
      keyboardOpen: keyboardOpen,
      modalOpen: modalOpen,
    );
    if (stateAnchor.signature.isEmpty) {
      return (inventory: null, target: null);
    }

    var target = _targetAtWithTokenMap(
      tapPosition,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
    );
    var inventory = _buildSceneInventoryFromTokenMap(
      tokenMap: tokenMap,
      rootRender: rootRender,
      route: route,
      stateAnchor: stateAnchor,
    );
    target = _snapPathlessTargetToInventory(
      target: target,
      inventory: inventory,
      tapPosition: tapPosition,
      rootRender: rootRender,
    );
    inventory = _injectTapTargetIntoInventory(
      inventory: inventory,
      target: target,
      tapPosition: tapPosition,
      stateAnchor: stateAnchor,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
    );
    return (inventory: inventory, target: target);
  }

  /// Resolves a [TugboatTargetAnchor] for the [Scrollable] element that emitted
  /// a scroll notification.
  TugboatTargetAnchor? scrollableAnchorFor(
    Element scrollableElement, {
    required String? route,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootContext is! Element || rootRender is! RenderBox) return null;

    final tokenMap = _buildTokenMap(rootContext, rootRender);
    final viewport = rootRender.size;
    final anchor = _anchorForElement(
      hitElement: scrollableElement,
      rootRender: rootRender,
      viewport: viewport,
      route: route,
      tokenMap: tokenMap,
    );
    if (anchor.fingerprint == null || anchor.fingerprint!.isEmpty) {
      return null;
    }
    return anchor;
  }

  /// Nearest enclosing [TugboatSubView] label for section attribution.
  String? subViewLabelFor(Element element) {
    String? label;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is TugboatSubView) {
        label = (ancestor.widget as TugboatSubView).label;
        return false;
      }
      return true;
    });
    return label;
  }

  TugboatTargetAnchor? _targetAtWithTokenMap(
    Offset globalPosition, {
    required String? route,
    required _TokenMap tokenMap,
    required RenderBox rootRender,
  }) {
    final viewport = rootRender.size;
    final result = BoxHitTestResult();
    rootRender.hitTest(result, position: globalPosition);

    TugboatTargetAnchor? roleOnly;
    TugboatTargetAnchor? fallback;
    for (final entry in result.path) {
      if (entry.target is! RenderObject) continue;
      final element = tokenMap.renderElements[entry.target as RenderObject];
      if (element == null || _isCaptureChrome(element.widget)) continue;

      final anchor = _anchorForElement(
        hitElement: element,
        rootRender: rootRender,
        viewport: viewport,
        route: route,
        tokenMap: tokenMap,
      );
      final hasPath = anchor.canonicalPath?.isNotEmpty ?? false;
      // Prefer an anchor that is both actionable and structurally addressable.
      // A role without a canonical path (e.g. a Texture overlay with a
      // long-press ancestor) cannot join a scene inventory, so keep scanning
      // for a deeper hit entry that can.
      if (anchor.role != null && hasPath) return anchor;
      if (anchor.role != null) {
        roleOnly ??= anchor;
      } else {
        fallback ??= anchor;
      }
    }
    return roleOnly ?? fallback;
  }

  TugboatTargetAnchor _anchorForElement({
    required Element hitElement,
    required RenderBox rootRender,
    required Size viewport,
    required String? route,
    required _TokenMap tokenMap,
  }) {
    String? role;
    bool? enabled;
    final actions = <String>{};
    String? widgetType;
    Element? boundsElement;
    Element? fingerprintElement;

    void inspectElement(Element element) {
      final widget = element.widget;
      final widgetRole = _roleForWidget(widget, actions);
      if (widgetRole != null) {
        role ??= widgetRole.$1;
        enabled ??= widgetRole.$2;
        boundsElement ??= element;
        widgetType ??= _widgetName(widget);
        fingerprintElement ??= element;
      } else if (widgetType == null && !_isCaptureChrome(widget)) {
        widgetType = _widgetName(widget);
      }
    }

    inspectElement(hitElement);
    hitElement.visitAncestorElements((ancestor) {
      inspectElement(ancestor);
      return true;
    });

    final anchorElement = boundsElement ?? hitElement;

    Rect? bounds;
    final render = anchorElement.renderObject;
    if (render is RenderBox && render.hasSize) {
      bounds = MatrixUtils.transformRect(
        render.getTransformTo(rootRender),
        render.paintBounds,
      );
    }

    final relativePosition = _relativePosition(bounds, viewport);
    final sortedActions = actions.toList()..sort();

    final routeKey = _resolveRouteKey(route, tokenMap);
    final fpElement = fingerprintElement ?? hitElement;
    final tagId = _tagIdForElement(fpElement, tokenMap);
    // The path already carries hashed discriminators (e.g. `[item:a1b2]`), so
    // it is the sole structural determinant of identity.
    final path = _pathFor(fpElement, tokenMap);

    // Hash input includes the full structural path. It is the determinant of
    // identity but far too verbose to ship on every event, so it stays here.
    final hashParts = <String, String>{'routeKey': routeKey, 'path': path};
    final fingerprint = _fingerprintForParts(hashParts);
    final tagFingerprint = tagId == null
        ? null
        : _fingerprintForParts({'routeKey': routeKey, 'tag': tagId});

    // Serialized evidence: only the small, human-meaningful fields. The full
    // path lives in [fingerprint], not on the wire.
    final fingerprintParts = <String, String>{
      'schemaVersion': tugboatFingerprintSchemaVersion.toString(),
      'routeKey': routeKey,
      if (tagId != null) 'tag': tagId,
    };

    // A target is well-identified if it (or any retained ancestor, e.g. its
    // list row) carries a meaningful static discriminator.
    final hasDiscriminator = _hasInheritedDiscriminator(fpElement, tokenMap);
    final pathConfidence = hasDiscriminator ? 'medium' : 'low';

    return TugboatTargetAnchor(
      schemaVersion: tugboatFingerprintSchemaVersion,
      widgetType: widgetType,
      role: role,
      fingerprint: fingerprint.isEmpty ? null : fingerprint,
      fingerprintConfidence: fingerprint.isEmpty
          ? null
          : _confidenceFloor([_routeKeyConfidence(routeKey), pathConfidence]),
      tagFingerprint: tagFingerprint,
      fingerprintParts: fingerprintParts,
      canonicalPath: path,
      relativePosition: relativePosition,
      enabled: enabled,
      actions: sortedActions,
    );
  }

  _TokenMap _buildTokenMap(Element rootElement, RenderBox rootRender) {
    final tokens = <Element, String>{};
    final retainedParents = <Element, Element?>{};
    final tagIds = <Element, String>{};
    final labelAnnotations = <Element, String>{};
    final hasBareItem = <Element, bool>{};
    final isActionable = <Element, bool>{};
    final ordinalCounters = <Object, int>{};
    final renderElements = <RenderObject, Element>{};
    final included = _collectIncludedElements(rootElement);
    String? subLabel;

    void visit(
      Element element,
      Element? retainedParent,
      bool inList,
      bool sensitive,
    ) {
      final widget = element.widget;
      if (!included.elements.contains(element)) return;
      if (_hidesSubtree(widget) || widget is TugboatInternal) return;
      final isSensitive = sensitive || widget is TugboatSensitive;
      final renderObject = element.renderObject;
      if (renderObject != null) renderElements[renderObject] = element;
      if (widget is TugboatSubView && subLabel == null) {
        subLabel = widget.label;
      }

      final retainable = _isRetainable(element, rootRender);
      final canonical = retainable ? _canonicalType(widget) : null;
      final role = retainable ? _roleForWidget(widget, <String>{}) : null;
      // Salient-node retention: actionable widgets must appear in the path even
      // when they sit on the wrapper denylist (e.g. InkWell, InkResponse).
      final retainType =
          canonical ??
          (role != null && role.$2 != false
              ? _actionableTypeName(widget)
              : null);
      Element? newRetainedParent = retainedParent;
      String? token;
      var bareItem = false;

      if (retainType != null) {
        if (inList) {
          // Collapse the row's positional index to `[item]`, but bake any safe
          // static discriminator into the token so descendants inherit it via
          // their path (e.g. `[item:a1b2]/ListTile#0`).
          bareItem = true;
          final discriminator = _safeStaticDiscriminatorForItem(
            element,
            isSensitive,
          );
          if (discriminator != null) {
            token = '[item:$discriminator]';
            labelAnnotations[element] = discriminator;
            bareItem = false;
          } else {
            token = '[item]';
          }
          hasBareItem[element] = bareItem;
        } else {
          final counterKey = Object.hash(retainedParent, retainType);
          final ordinal = ordinalCounters[counterKey] ?? 0;
          ordinalCounters[counterKey] = ordinal + 1;
          token = '$retainType#$ordinal';

          // Discriminators are only embedded for list rows (`[item]`) and via
          // explicit tags. Container nodes are left as bare `Type#ordinal` to
          // avoid leaking dynamic descendant text into the path.
          final tagId = _tagIdFromWidget(widget);
          if (tagId != null) {
            tagIds[element] = tagId;
          }
        }

        tokens[element] = token;
        retainedParents[element] = retainedParent;
        newRetainedParent = element;
      }

      if (role != null && role.$2 != false && tokens.containsKey(element)) {
        isActionable[element] = true;
      }

      // Once we emit an `[item]` token we are inside a single list entry, so
      // descendants resume normal tokenization (and only a *nested* list
      // container re-enters list mode). This prevents `[item]/[item]/...` chains.
      final childInList = token == '[item]'
          ? false
          : (inList || _isListContainer(widget));
      element.debugVisitOnstageChildren((child) {
        visit(
          child,
          newRetainedParent ?? retainedParent,
          childInList,
          isSensitive,
        );
      });
    }

    rootElement.debugVisitOnstageChildren(
      (child) => visit(child, null, false, false),
    );

    final actionableSummary = <String, int>{};
    final actionablePaths = <String>{};
    for (final element in included.elements) {
      if (isActionable[element] != true || !tokens.containsKey(element)) {
        continue;
      }
      if (_hasActionableDescendant(element, isActionable)) continue;
      final role = _roleForWidget(element.widget, <String>{});
      if (role == null || role.$2 == false) continue;
      actionableSummary[role.$1] = (actionableSummary[role.$1] ?? 0) + 1;
      actionablePaths.add(_pathForMaps(element, tokens, retainedParents));
    }

    final sortedPaths =
        actionablePaths.map(_normalizeItemPathForSignature).toSet().toList()
          ..sort();
    final structuralRouteSignature = tugboatLabelHash(sortedPaths.join('|'));

    return _TokenMap(
      tokens: tokens,
      retainedParents: retainedParents,
      tagIds: tagIds,
      labelAnnotations: labelAnnotations,
      hasBareItem: hasBareItem,
      isActionable: isActionable,
      structuralRouteSignature: structuralRouteSignature,
      renderElements: renderElements,
      hasBlockingOverlay: included.hasBlockingOverlay,
      includedElements: included.elements,
      actionableSummary: actionableSummary,
      subLabel: subLabel,
    );
  }

  _IncludedElements _collectIncludedElements(Element root) {
    _IncludedElements collect(Element element) {
      final widget = element.widget;
      final renderObject = element.renderObject;
      if (_hidesSubtree(widget) || widget is TugboatInternal) {
        return const _IncludedElements();
      }
      if (renderObject is RenderOffstage && renderObject.offstage) {
        return const _IncludedElements();
      }
      if (renderObject is RenderOpacity && renderObject.opacity == 0) {
        return const _IncludedElements();
      }
      if (renderObject is RenderAnimatedOpacity &&
          renderObject.opacity.value == 0) {
        return const _IncludedElements();
      }
      if (renderObject is RenderExcludeSemantics && renderObject.excluding) {
        return const _IncludedElements();
      }

      final elements = <Element>{element};
      var pendingBlocker =
          renderObject is RenderBlockSemantics && renderObject.blocking;
      var hasBlockingOverlay = false;
      element.visitChildElements((child) {
        final childResult = collect(child);
        if (childResult.pendingBlocker && _isOverlayLevel(element)) {
          elements
            ..clear()
            ..add(element);
          pendingBlocker = false;
          hasBlockingOverlay = true;
        }
        elements.addAll(childResult.elements);
        pendingBlocker = pendingBlocker || childResult.pendingBlocker;
        hasBlockingOverlay =
            hasBlockingOverlay || childResult.hasBlockingOverlay;
      });
      return _IncludedElements(
        elements: elements,
        pendingBlocker: pendingBlocker,
        hasBlockingOverlay: hasBlockingOverlay,
      );
    }

    return collect(root);
  }

  bool _hasActionableDescendant(
    Element element,
    Map<Element, bool> isActionable,
  ) {
    var found = false;
    void walk(Element node) {
      node.visitChildElements((child) {
        if (isActionable[child] == true) {
          found = true;
          return;
        }
        walk(child);
      });
    }

    walk(element);
    return found;
  }

  bool _isOverlayLevel(Element element) {
    var found = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor is StatefulElement && ancestor.state is OverlayState) {
        found = true;
      }
      return false;
    });
    return found;
  }

  bool _isRetainable(Element element, RenderBox rootRender) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize ||
        renderObject.size.isEmpty) {
      return false;
    }
    try {
      final bounds = MatrixUtils.transformRect(
        renderObject.getTransformTo(rootRender),
        renderObject.paintBounds,
      );
      return bounds.width > 0 &&
          bounds.height > 0 &&
          bounds.overlaps(rootRender.paintBounds);
    } catch (_) {
      return false;
    }
  }

  String _pathFor(Element element, _TokenMap tokenMap) =>
      _pathForMaps(element, tokenMap.tokens, tokenMap.retainedParents);

  /// Whether [element] or any of its retained ancestors carries a meaningful
  /// static discriminator (a row label such as `Pro`, or a labelled control).
  bool _hasInheritedDiscriminator(Element element, _TokenMap tokenMap) {
    Element? current = element;
    while (current != null) {
      if (tokenMap.labelAnnotations[current] != null) return true;
      current = tokenMap.retainedParents[current];
    }
    return false;
  }

  String _pathForMaps(
    Element element,
    Map<Element, String> tokens,
    Map<Element, Element?> retainedParents,
  ) {
    Element? walkStart = element;
    if (!tokens.containsKey(walkStart)) {
      Element? tokenizedAncestor;
      walkStart.visitAncestorElements((ancestor) {
        if (tokens.containsKey(ancestor)) {
          tokenizedAncestor = ancestor;
          return false;
        }
        return true;
      });
      walkStart = tokenizedAncestor ?? walkStart;
    }

    final parts = <String>[];
    Element? current = walkStart;
    while (current != null) {
      final token = tokens[current];
      if (token != null) parts.add(token);
      current = retainedParents[current];
    }
    return parts.reversed.join('/');
  }

  String? _tagIdFromWidget(Widget widget) {
    if (widget is TugboatTag) return widget.id;
    final key = widget.key;
    if (key is ValueKey<String>) return key.value;
    return null;
  }

  String? _tagIdForElement(Element element, _TokenMap tokenMap) {
    var current = element;
    while (true) {
      final tag = tokenMap.tagIds[current];
      if (tag != null) return tag;
      final widgetTag = _tagIdFromWidget(current.widget);
      if (widgetTag != null) return widgetTag;
      Element? parent;
      current.visitAncestorElements((ancestor) {
        parent = ancestor;
        return false;
      });
      if (parent == null) break;
      current = parent!;
    }
    return null;
  }

  String _resolveRouteKey(String? route, _TokenMap tokenMap) {
    if (route != null && route.isNotEmpty && !_isAnonymousRouteName(route)) {
      return route;
    }
    return 'struct:${tokenMap.structuralRouteSignature}';
  }

  bool _isAnonymousRouteName(String route) {
    if (route.startsWith('_')) return true;
    const anonymousFragments = [
      'PageRoute',
      'ModalRoute',
      'CupertinoPageRoute',
      'MaterialPageRoute',
      'DialogRoute',
      'PopupRoute',
    ];
    return anonymousFragments.any(route.contains);
  }

  String? _safeStaticDiscriminatorForItem(Element element, bool sensitive) {
    if (sensitive) return null;

    String? label;
    void visit(Element node, bool nodeSensitive) {
      if (label != null) return;
      final nodeWidget = node.widget;
      if (_hidesSubtree(nodeWidget) || nodeWidget is TugboatInternal) return;
      final isNodeSensitive = nodeSensitive || nodeWidget is TugboatSensitive;
      if (isNodeSensitive) return;

      if (nodeWidget is Text) {
        final data = nodeWidget.data ?? nodeWidget.textSpan?.toPlainText();
        if (data != null && _isSafeStaticLabel(data)) {
          label = data;
          return;
        }
      }
      if (nodeWidget is Icon && nodeWidget.icon != null) {
        label = tugboatIconLabel(nodeWidget.icon!);
        return;
      }
      node.debugVisitOnstageChildren((child) => visit(child, isNodeSensitive));
    }

    visit(element, sensitive);
    return label == null ? null : tugboatLabelHash(label!);
  }

  bool _isSafeStaticLabel(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 24) return false;
    if (trimmed.contains('\n')) return false;
    if (RegExp(r'\d').hasMatch(trimmed)) return false;
    if (_hasDynamicMarkers(trimmed)) return false;
    if (_isNumericHeavy(trimmed)) return false;
    return true;
  }

  bool _hasDynamicMarkers(String value) {
    final lower = value.toLowerCase();
    if (value.contains('@')) return true;
    if (lower.contains('http://') || lower.contains('https://')) return true;
    if (RegExp(
      r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
      caseSensitive: false,
    ).hasMatch(value)) {
      return true;
    }
    return false;
  }

  bool _isNumericHeavy(String value) {
    final digits = RegExp(r'\d').allMatches(value).length;
    if (digits == 0) return false;
    if (digits / value.length > 0.5) return true;
    if (RegExp(r'\d{1,3}([.,]\d{3})+').hasMatch(value)) return true;
    if (RegExp(r'\d+[/\-]\d+').hasMatch(value)) return true;
    return false;
  }

  String? _normalizedWidgetTypeName(Widget widget) {
    if (_isCaptureChrome(widget)) return null;
    if (widget is TugboatInternal || widget is TugboatTag) return null;
    var type = _widgetName(widget);
    // Collapse generic arguments so `BlocProvider<AuthBloc>` and
    // `BlocBuilder<BillingBloc, BillingState>` match their base denylist name.
    final generic = type.indexOf('<');
    if (generic != -1) type = type.substring(0, generic);
    if (type.startsWith('_')) return null;
    // All Sliver* widgets are scroll plumbing; the meaningful unit is the row.
    if (type.startsWith('Sliver')) return null;
    return type;
  }

  String? _canonicalType(Widget widget) {
    final type = _normalizedWidgetTypeName(widget);
    if (type == null || _canonicalDenylist.contains(type)) return null;
    return type;
  }

  /// Type name for an actionable widget that must be retained even when it is
  /// on the wrapper denylist (e.g. InkWell).
  String? _actionableTypeName(Widget widget) =>
      _normalizedWidgetTypeName(widget);

  String _widgetName(Widget widget) =>
      widgetNames[widget.runtimeType] ?? widget.runtimeType.toString();

  bool _isListContainer(Widget widget) {
    // Only the Scrollable primitive (which ListView/GridView/PageView all build)
    // arms list mode, so we don't double-trigger and treat the inner Scrollable
    // itself as an `[item]`. Bare slivers are covered for Scrollable-less cases.
    if (widget is Scrollable) return true;
    final type = widget.runtimeType.toString();
    return type.startsWith('Sliver');
  }

  (String, bool?)? _roleForWidget(Widget widget, Set<String> actions) {
    if (widget is ButtonStyleButton) {
      if (widget.onPressed != null) actions.add('tap');
      return ('button', widget.onPressed != null);
    }
    if (widget is IconButton) {
      if (widget.onPressed != null) actions.add('tap');
      return ('button', widget.onPressed != null);
    }
    if (widget is CupertinoButton) {
      if (widget.onPressed != null) actions.add('tap');
      return ('button', widget.onPressed != null);
    }
    if (widget is MaterialButton) {
      if (widget.onPressed != null) actions.add('tap');
      return ('button', widget.onPressed != null);
    }
    if (widget is FloatingActionButton) {
      if (widget.onPressed != null) actions.add('tap');
      return ('button', widget.onPressed != null);
    }
    if (widget is PopupMenuButton) {
      if (widget.enabled) actions.add('tap');
      return ('button', widget.enabled);
    }
    if (widget is PopupMenuItem) {
      if (widget.enabled) actions.add('tap');
      return ('button', widget.enabled);
    }
    if (widget is ExpansionTile) {
      if (widget.enabled) actions.add('tap');
      return ('button', widget.enabled);
    }
    if (widget is InkWell) {
      if (widget.onTap != null) actions.add('tap');
      return ('button', widget.onTap != null);
    }
    if (widget is InkResponse) {
      if (widget.onTap != null) actions.add('tap');
      return ('button', widget.onTap != null);
    }
    if (widget is ListTile &&
        (widget.onTap != null || widget.onLongPress != null)) {
      if (widget.enabled && widget.onTap != null) {
        actions.add('tap');
      }
      if (widget.enabled && widget.onLongPress != null) {
        actions.add('longPress');
      }
      return ('button', widget.enabled);
    }
    if (widget is GestureDetector) {
      if (widget.onTap != null) actions.add('tap');
      if (widget.onDoubleTap != null) actions.add('doubleTap');
      if (widget.onLongPress != null) actions.add('longPress');
      if (actions.isNotEmpty) return ('button', true);
    }
    if (widget is InputChip ||
        widget is ActionChip ||
        widget is FilterChip ||
        widget is ChoiceChip) {
      final enabled = switch (widget) {
        InputChip w => w.onPressed != null || w.onSelected != null,
        ActionChip w => w.onPressed != null,
        FilterChip w => w.onSelected != null,
        ChoiceChip w => w.onSelected != null,
        _ => false,
      };
      if (enabled) actions.add('tap');
      return ('button', enabled);
    }
    if (widget is Scrollable) {
      actions.add('scroll');
      return ('scrollable', null);
    }
    if (widget is Checkbox) {
      if (widget.onChanged != null) actions.add('tap');
      return ('checkbox', widget.onChanged != null);
    }
    if (widget is CheckboxListTile) {
      if (widget.onChanged != null) actions.add('tap');
      return ('checkbox', widget.onChanged != null);
    }
    if (widget is Switch) {
      if (widget.onChanged != null) actions.add('tap');
      return ('switch', widget.onChanged != null);
    }
    if (widget is CupertinoSwitch) {
      if (widget.onChanged != null) actions.add('tap');
      return ('switch', widget.onChanged != null);
    }
    if (widget is SwitchListTile) {
      if (widget.onChanged != null) actions.add('tap');
      return ('switch', widget.onChanged != null);
    }
    if (widget is Radio || widget is RadioListTile) {
      final enabled = switch (widget) {
        // ignore: deprecated_member_use
        Radio w => w.onChanged != null,
        // ignore: deprecated_member_use
        RadioListTile w => w.onChanged != null,
        _ => false,
      };
      if (enabled) actions.add('tap');
      return ('radio', enabled);
    }
    if (widget is Slider ||
        widget is RangeSlider ||
        widget is CupertinoSlider) {
      final enabled = switch (widget) {
        Slider w => w.onChanged != null,
        RangeSlider w => w.onChanged != null,
        CupertinoSlider w => w.onChanged != null,
        _ => false,
      };
      if (enabled) actions.add('slide');
      return ('slider', enabled);
    }
    if (widget is DropdownButton) {
      final enabled = widget.onChanged != null;
      if (enabled) actions.add('tap');
      return ('dropdown', enabled);
    }
    if (widget is EditableText ||
        widget is TextField ||
        widget is TextFormField) {
      final enabled = switch (widget) {
        TextField w => w.enabled ?? true,
        TextFormField w => w.enabled,
        EditableText w => !w.readOnly,
        _ => true,
      };
      if (enabled) actions.add('input');
      return ('textField', enabled);
    }
    return null;
  }

  bool _isCaptureChrome(Widget widget) {
    return widget is RepaintBoundary ||
        widget is NotificationListener ||
        widget is Listener ||
        widget is IgnorePointer ||
        widget is AbsorbPointer ||
        widget is Semantics;
  }

  TugboatStateAnchor buildStateAnchor({
    required String? route,
    required bool keyboardOpen,
    required bool modalOpen,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootContext is! Element || rootRender is! RenderBox) {
      return TugboatStateAnchor(keyboardOpen: keyboardOpen, modalOpen: modalOpen);
    }

    final tokenMap = _buildTokenMap(rootContext, rootRender);
    return _stateAnchorFromTokenMap(
      tokenMap: tokenMap,
      route: route,
      keyboardOpen: keyboardOpen,
      modalOpen: modalOpen,
    );
  }

  TugboatStateAnchor _stateAnchorFromTokenMap({
    required _TokenMap tokenMap,
    required String? route,
    required bool keyboardOpen,
    required bool modalOpen,
  }) {
    final routeKey = _resolveRouteKey(route, tokenMap);
    final actionableSummary = tokenMap.actionableSummary;
    final subLabel = tokenMap.subLabel;
    final effectiveModalOpen = modalOpen || tokenMap.hasBlockingOverlay;
    // fp schema v6: state identity is coarse — route + overlay flags + subLabel
    // only. Dynamic list length, scroll viewport, and per-item path multiplicity
    // must not fork signatures across production sessions on the same screen.
    final hashParts = <String, String>{
      'routeKey': routeKey,
      'schemaVersion': tugboatFingerprintSchemaVersion.toString(),
      if (keyboardOpen) 'keyboardOpen': 'true',
      if (effectiveModalOpen) 'modalOpen': 'true',
      if (subLabel != null && subLabel.isNotEmpty) 'subLabel': subLabel,
    };
    final signature = _fingerprintForParts(hashParts);

    // Serialized evidence: compact descriptors only, never the skeleton.
    final signatureParts = <String, String>{
      'schemaVersion': tugboatFingerprintSchemaVersion.toString(),
      'routeKey': routeKey,
      if (keyboardOpen) 'keyboardOpen': 'true',
      if (effectiveModalOpen) 'modalOpen': 'true',
      if (subLabel != null && subLabel.isNotEmpty) 'subLabel': subLabel,
    };

    final pathConfidence = tokenMap.isActionable.isNotEmpty ? 'medium' : 'low';

    return TugboatStateAnchor(
      schemaVersion: tugboatFingerprintSchemaVersion,
      actionableSummary: actionableSummary,
      keyboardOpen: keyboardOpen,
      modalOpen: effectiveModalOpen,
      subLabel: subLabel,
      signature: signature,
      signatureConfidence: _confidenceFloor([
        _routeKeyConfidence(routeKey),
        pathConfidence,
      ]),
      signatureParts: signatureParts,
    );
  }

  /// Minimum normalized paint area for tokenized [Text] widgets to qualify as
  /// content-tier inventory entries.
  static const double _largeTextAreaThreshold = 0.02;

  /// Enumerates tokenized actionable elements, [Image] widgets, and large
  /// [Text] blocks on the current screen. Fingerprints match [targetAt] for the
  /// same element.
  TugboatSceneInventory? buildSceneInventory({
    required String? route,
    required bool keyboardOpen,
    required bool modalOpen,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootContext is! Element || rootRender is! RenderBox) return null;

    final tokenMap = _buildTokenMap(rootContext, rootRender);
    final stateAnchor = _stateAnchorFromTokenMap(
      tokenMap: tokenMap,
      route: route,
      keyboardOpen: keyboardOpen,
      modalOpen: modalOpen,
    );
    if (stateAnchor.signature.isEmpty) return null;

    return _buildSceneInventoryFromTokenMap(
      tokenMap: tokenMap,
      rootRender: rootRender,
      route: route,
      stateAnchor: stateAnchor,
    );
  }

  TugboatSceneInventory? _buildSceneInventoryFromTokenMap({
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required String? route,
    required TugboatStateAnchor stateAnchor,
  }) {
    final routeKey = _resolveRouteKey(route, tokenMap);
    final viewport = rootRender.size;
    final contentEntries = <TugboatSceneInventoryEntry>[];
    final interactiveByFingerprint = <String, TugboatSceneInventoryEntry>{};
    final seenContentFingerprints = <String>{};
    final hitCache = <String, TugboatTargetAnchor?>{};

    for (final element in tokenMap.includedElements) {
      if (!tokenMap.tokens.containsKey(element)) continue;

      final widget = element.widget;
      final isImage = widget is Image;
      final isLargeText =
          widget is Text &&
          _isLargeTextBounds(_boundsForElement(element, rootRender, viewport));
      final isActionable = tokenMap.isActionable[element] == true;
      if (!isActionable && !isImage && !isLargeText) continue;

      final structuralPath = _pathFor(element, tokenMap);
      final bounds = _boundsForElement(element, rootRender, viewport);
      if (bounds == null) continue;

      if (isActionable) {
        final result = _interactiveInventoryEntry(
          element: element,
          widget: widget,
          structuralPath: structuralPath,
          bounds: bounds,
          routeKey: routeKey,
          route: route,
          tokenMap: tokenMap,
          rootRender: rootRender,
          viewport: viewport,
          hitCache: hitCache,
        );
        if (result == null) continue;
        _accumulateInteractiveEntry(
          interactiveByFingerprint,
          result.entry,
          result.structuralFingerprint,
        );
        continue;
      }

      final fingerprint = _fingerprintForParts({
        'routeKey': routeKey,
        'path': structuralPath,
      });
      if (fingerprint.isEmpty || !seenContentFingerprints.add(fingerprint)) {
        continue;
      }

      contentEntries.add(
        TugboatSceneInventoryEntry(
          fingerprint: fingerprint,
          canonicalPath: structuralPath,
          widgetType: _widgetName(widget),
          role: 'display',
          boundsNorm: bounds,
          tier: 'content',
        ),
      );
    }

    final elements = [...interactiveByFingerprint.values, ...contentEntries];
    if (elements.isEmpty) return null;

    return _inventoryFromElements(
      stateAnchor: stateAnchor,
      routeKey: routeKey,
      elements: elements,
    );
  }

  TugboatSceneInventory _inventoryFromElements({
    required TugboatStateAnchor stateAnchor,
    required String routeKey,
    required List<TugboatSceneInventoryEntry> elements,
  }) {
    final fingerprints = elements.map((entry) => entry.fingerprint).toList()
      ..sort();
    final inventoryHash = tugboatLabelHash(fingerprints.join('|'));

    return TugboatSceneInventory(
      stateAnchor: stateAnchor,
      stateSignature: stateAnchor.signature,
      inventoryHash: inventoryHash,
      routeKey: routeKey,
      elements: elements,
    );
  }

  void _accumulateInteractiveEntry(
    Map<String, TugboatSceneInventoryEntry> interactiveByFingerprint,
    TugboatSceneInventoryEntry entry,
    String structuralFingerprint,
  ) {
    final existing = interactiveByFingerprint[entry.fingerprint];
    if (existing == null) {
      final aliases = _mergeAliasFingerprints(
        existingAliases: const [],
        primaryFingerprint: entry.fingerprint,
        structuralFingerprint: structuralFingerprint,
      );
      interactiveByFingerprint[entry.fingerprint] = entry.copyWith(
        aliases: aliases,
      );
      return;
    }

    final aliases = _mergeAliasFingerprints(
      existingAliases: existing.aliases,
      primaryFingerprint: entry.fingerprint,
      structuralFingerprint: structuralFingerprint,
    );
    interactiveByFingerprint[entry.fingerprint] = existing.copyWith(
      aliases: aliases,
    );
  }

  List<String> _mergeAliasFingerprints({
    required List<String> existingAliases,
    required String primaryFingerprint,
    required String structuralFingerprint,
  }) {
    final merged = {...existingAliases};
    if (structuralFingerprint.isNotEmpty &&
        structuralFingerprint != primaryFingerprint) {
      merged.add(structuralFingerprint);
    }
    final sorted = merged.toList()..sort();
    return sorted;
  }

  bool _inventoryContainsFingerprint(
    TugboatSceneInventory? inventory,
    String fingerprint,
  ) {
    if (inventory == null) return false;
    for (final entry in inventory.elements) {
      if (entry.fingerprint == fingerprint) return true;
      if (entry.aliases.contains(fingerprint)) return true;
    }
    return false;
  }

  /// When hit-testing produced a target without a canonical path (e.g. a
  /// decorated box that is not part of the token map), its fingerprint can
  /// never join the scene inventory. Re-anchor the tap to the smallest
  /// interactive inventory element whose bounds contain the tap point so the
  /// event and the inventory agree on identity.
  ///
  /// The snap is meant to rejoin the *same* conceptual element (a video's
  /// gesture wrapper behind its Texture, a control mid-transition), not to
  /// attribute the tap to whatever sits underneath an opaque overlay. Two
  /// guards enforce that: only interactive-tier entries qualify, and the
  /// candidate's area must be comparable to the area of the render object the
  /// pointer actually hit — a small button underneath a screen-sized overlay
  /// fails that ratio and the tap stays pathless.
  TugboatTargetAnchor? _snapPathlessTargetToInventory({
    required TugboatTargetAnchor? target,
    required TugboatSceneInventory? inventory,
    required Offset tapPosition,
    required RenderBox rootRender,
  }) {
    if (target == null || inventory == null) return target;
    final hasPath = target.canonicalPath?.isNotEmpty ?? false;
    if (hasPath) return target;
    final viewport = rootRender.size;
    if (viewport.width <= 0 || viewport.height <= 0) return target;

    final nx = tapPosition.dx / viewport.width;
    final ny = tapPosition.dy / viewport.height;
    final hitAreaNorm = _hitLeafAreaNorm(rootRender, tapPosition);

    TugboatSceneInventoryEntry? best;
    var bestArea = double.infinity;
    for (final entry in inventory.elements) {
      if (entry.tier != 'interactive') continue;
      if (entry.role == null && entry.actions.isEmpty) continue;
      final b = entry.boundsNorm;
      final within =
          nx >= b.left &&
          nx <= b.left + b.width &&
          ny >= b.top &&
          ny <= b.top + b.height;
      if (!within) continue;
      final area = b.width * b.height;
      // Reject candidates far smaller than the surface the pointer actually
      // landed on: they are occluded content, not the tapped element.
      if (hitAreaNorm != null && area < hitAreaNorm * 0.5) continue;
      if (area < bestArea) {
        bestArea = area;
        best = entry;
      }
    }
    if (best == null) return target;

    return TugboatTargetAnchor(
      schemaVersion: target.schemaVersion,
      widgetType: best.widgetType ?? target.widgetType,
      role: best.role ?? target.role,
      fingerprint: best.fingerprint,
      fingerprintConfidence: 'low',
      // The fingerprint now describes the inventory element, so the original
      // anchor's parts would be stale; inventory entries carry no parts.
      fingerprintParts: const {},
      tagFingerprint: target.tagFingerprint,
      canonicalPath: best.canonicalPath,
      relativePosition: target.relativePosition,
      enabled: best.enabled ?? target.enabled,
      actions: best.actions.isNotEmpty ? best.actions : target.actions,
    );
  }

  /// Normalized area of the deepest render box the pointer actually hit.
  /// Used to keep the pathless-tap snap from re-anchoring to occluded
  /// elements that are much smaller than the hit surface.
  double? _hitLeafAreaNorm(RenderBox rootRender, Offset tapPosition) {
    final viewport = rootRender.size;
    final result = BoxHitTestResult();
    rootRender.hitTest(result, position: tapPosition);
    for (final entry in result.path) {
      final hit = entry.target;
      if (hit is! RenderBox || !hit.hasSize) continue;
      final area =
          (hit.size.width / viewport.width) *
          (hit.size.height / viewport.height);
      if (area <= 0) continue;
      return area;
    }
    return null;
  }

  TugboatSceneInventory? _injectTapTargetIntoInventory({
    required TugboatSceneInventory? inventory,
    required TugboatTargetAnchor? target,
    required Offset tapPosition,
    required TugboatStateAnchor stateAnchor,
    required String? route,
    required _TokenMap tokenMap,
    required RenderBox rootRender,
  }) {
    final fingerprint = target?.fingerprint;
    if (fingerprint == null || fingerprint.isEmpty) {
      return inventory;
    }
    if (_inventoryContainsFingerprint(inventory, fingerprint)) {
      return inventory;
    }

    final routeKey = _resolveRouteKey(route, tokenMap);
    final viewport = rootRender.size;
    final injectedEntry = _entryFromTargetAnchor(
      target: target!,
      tapPosition: tapPosition,
      tokenMap: tokenMap,
      rootRender: rootRender,
      viewport: viewport,
    );
    if (injectedEntry == null) return inventory;

    final elements = [
      ...(inventory?.elements ?? const <TugboatSceneInventoryEntry>[]),
      injectedEntry,
    ];
    return _inventoryFromElements(
      stateAnchor: stateAnchor,
      routeKey: inventory?.routeKey ?? routeKey,
      elements: elements,
    );
  }

  TugboatSceneInventoryEntry? _entryFromTargetAnchor({
    required TugboatTargetAnchor target,
    required Offset tapPosition,
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required Size viewport,
  }) {
    final fingerprint = target.fingerprint;
    final canonicalPath = target.canonicalPath;
    if (fingerprint == null ||
        fingerprint.isEmpty ||
        canonicalPath == null ||
        canonicalPath.isEmpty) {
      return null;
    }

    final bounds =
        _boundsAtTapPosition(
          tapPosition,
          tokenMap: tokenMap,
          rootRender: rootRender,
          viewport: viewport,
        ) ??
        TugboatNormalizedBounds(
          left: (tapPosition.dx / viewport.width).clamp(0.0, 1.0),
          top: (tapPosition.dy / viewport.height).clamp(0.0, 1.0),
          width: 0.01,
          height: 0.01,
        );

    return TugboatSceneInventoryEntry(
      fingerprint: fingerprint,
      canonicalPath: canonicalPath,
      widgetType: target.widgetType,
      role: target.role,
      actions: target.actions,
      enabled: target.enabled,
      boundsNorm: bounds,
      tier: 'interactive',
    );
  }

  TugboatNormalizedBounds? _boundsAtTapPosition(
    Offset tapPosition, {
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required Size viewport,
  }) {
    final result = BoxHitTestResult();
    rootRender.hitTest(result, position: tapPosition);
    for (final entry in result.path) {
      if (entry.target is! RenderObject) continue;
      final element = tokenMap.renderElements[entry.target as RenderObject];
      if (element == null || _isCaptureChrome(element.widget)) continue;
      return _boundsForElement(element, rootRender, viewport);
    }
    return null;
  }

  ({TugboatSceneInventoryEntry entry, String structuralFingerprint})?
  _interactiveInventoryEntry({
    required Element element,
    required Widget widget,
    required String structuralPath,
    required TugboatNormalizedBounds bounds,
    required String routeKey,
    required String? route,
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required Size viewport,
    required Map<String, TugboatTargetAnchor?> hitCache,
  }) {
    final structuralFingerprint = _fingerprintForParts({
      'routeKey': routeKey,
      'path': structuralPath,
    });

    final center = Offset(
      (bounds.left + bounds.width / 2) * viewport.width,
      (bounds.top + bounds.height / 2) * viewport.height,
    );
    final cacheKey = '${center.dx}|${center.dy}';
    final resolved = hitCache.putIfAbsent(
      cacheKey,
      () => _targetAtWithTokenMap(
        center,
        route: route,
        tokenMap: tokenMap,
        rootRender: rootRender,
      ),
    );

    final resolvedFingerprint = resolved?.fingerprint;
    final resolvedPath = resolved?.canonicalPath;
    if (resolvedFingerprint != null &&
        resolvedFingerprint.isNotEmpty &&
        resolvedPath != null &&
        resolvedPath.isNotEmpty &&
        _pathsOnSameChain(structuralPath, resolvedPath)) {
      return (
        entry: TugboatSceneInventoryEntry(
          fingerprint: resolvedFingerprint,
          canonicalPath: resolvedPath,
          widgetType: resolved?.widgetType ?? _widgetName(widget),
          role: resolved?.role,
          actions: resolved?.actions ?? const [],
          enabled: resolved?.enabled,
          boundsNorm: bounds,
          tier: 'interactive',
        ),
        structuralFingerprint: structuralFingerprint,
      );
    }

    if (_hasTokenizedActionableDescendant(
      element,
      tokenMap.isActionable,
      tokenMap.tokens,
    )) {
      return null;
    }

    if (structuralFingerprint.isEmpty) return null;

    final actions = <String>{};
    final roleInfo = _roleForWidget(widget, actions);

    return (
      entry: TugboatSceneInventoryEntry(
        fingerprint: structuralFingerprint,
        canonicalPath: structuralPath,
        widgetType: _widgetName(widget),
        role: roleInfo?.$1,
        actions: actions.toList()..sort(),
        enabled: roleInfo?.$2,
        boundsNorm: bounds,
        tier: 'interactive',
      ),
      structuralFingerprint: structuralFingerprint,
    );
  }

  bool _pathsOnSameChain(String leftPath, String rightPath) {
    return leftPath.startsWith(rightPath) || rightPath.startsWith(leftPath);
  }

  String _normalizeItemPathForSignature(String path) {
    return path.replaceAll(RegExp(r'\[item:[^\]]+\]'), '[item]');
  }

  bool _hasTokenizedActionableDescendant(
    Element element,
    Map<Element, bool> isActionable,
    Map<Element, String> tokens,
  ) {
    var found = false;
    void walk(Element node) {
      node.visitChildElements((child) {
        if (isActionable[child] == true && tokens.containsKey(child)) {
          found = true;
          return;
        }
        if (!found) walk(child);
      });
    }

    walk(element);
    return found;
  }

  bool _isLargeTextBounds(TugboatNormalizedBounds? bounds) {
    if (bounds == null) return false;
    return bounds.width * bounds.height >= _largeTextAreaThreshold;
  }

  TugboatNormalizedBounds? _boundsForElement(
    Element element,
    RenderBox rootRender,
    Size viewport,
  ) {
    final render = element.renderObject;
    if (render is! RenderBox || !render.hasSize) return null;
    try {
      final rect = MatrixUtils.transformRect(
        render.getTransformTo(rootRender),
        render.paintBounds,
      );
      return TugboatNormalizedBounds.fromRect(rect, viewport);
    } catch (_) {
      return null;
    }
  }

  String? _relativePosition(Rect? bounds, Size viewport) {
    if (bounds == null || viewport.height <= 0) return null;
    final centerY = bounds.center.dy / viewport.height;
    if (centerY < 0.33) return 'top';
    if (centerY > 0.66) return 'bottom';
    return 'center';
  }

  bool _hidesSubtree(Widget widget) {
    if (widget is Offstage) return widget.offstage;
    if (widget is Visibility) return !widget.visible;
    if (widget is Opacity) return widget.opacity == 0;
    return false;
  }

  /// Builds an exploration-only viewport semantic map from Flutter semantics,
  /// enriched with scene inventory fingerprints when overlap is clear.
  TugboatViewportSemanticMap? buildViewportSemanticMap({
    required TugboatSceneInventory inventory,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootRender is! RenderBox || !rootRender.hasSize) return null;

    final viewport = rootRender.size;
    if (viewport.width <= 0 || viewport.height <= 0) return null;

    WidgetsBinding.instance.pipelineOwner.flushSemantics();
    final rootNode = WidgetsBinding
        .instance
        .pipelineOwner
        .semanticsOwner
        ?.rootSemanticsNode;
    if (rootNode == null) return null;

    final nodes = <TugboatViewportSemanticNode>[];
    void walk(SemanticsNode node) {
      if (node.id != 0) {
        final built = _viewportSemanticNodeFromSemantics(
          node: node,
          rootRender: rootRender,
          viewport: viewport,
          inventory: inventory,
        );
        if (built != null) {
          nodes.add(built);
        }
      }
      node.visitChildren((SemanticsNode child) {
        walk(child);
        return true;
      });
    }

    walk(rootNode);
    if (nodes.isEmpty) return null;

    nodes.sort((left, right) => left.nodeId.compareTo(right.nodeId));
    final summary = _viewportSemanticMapSummary(nodes);
    final mapHash = _viewportSemanticMapHash(nodes);

    return TugboatViewportSemanticMap(
      stateAnchor: inventory.stateAnchor,
      stateSignature: inventory.stateSignature,
      routeKey: inventory.routeKey,
      viewport: viewport,
      nodes: nodes,
      summary: summary,
      mapHash: mapHash,
    );
  }

  /// Resolves a tap point against [map], preferring enabled actionable nodes,
  /// then smallest bounds, then deepest node.
  TugboatViewportSemanticResolution resolveTapOnViewportSemanticMap({
    required Offset tapPosition,
    required TugboatViewportSemanticMap map,
    required RenderBox rootRender,
  }) {
    final viewport = map.viewport;
    if (viewport.width <= 0 || viewport.height <= 0) {
      return const TugboatViewportSemanticResolution(
        status: 'outside_known_ui',
      );
    }

    final localPoint = rootRender.globalToLocal(tapPosition);
    final nx = localPoint.dx / viewport.width;
    final ny = localPoint.dy / viewport.height;

    final candidates = map.nodes
        .where((node) => _normalizedPointInBounds(nx, ny, node.boundsNorm))
        .toList();
    if (candidates.isEmpty) {
      return const TugboatViewportSemanticResolution(
        status: 'outside_known_ui',
      );
    }

    final enabledActionable = candidates
        .where(
          (node) => node.isActionable && node.enabled != false,
        )
        .toList();
    if (enabledActionable.isNotEmpty) {
      return _resolutionForNode(
        node: _pickViewportSemanticWinner(enabledActionable),
        status: 'matched_actionable',
      );
    }

    final disabledActionable = candidates
        .where(
          (node) => node.isActionable && node.enabled == false,
        )
        .toList();
    if (disabledActionable.isNotEmpty) {
      return _resolutionForNode(
        node: _pickViewportSemanticWinner(disabledActionable),
        status: 'matched_disabled',
      );
    }

    return _resolutionForNode(
      node: _pickViewportSemanticWinner(candidates),
      status: 'matched_non_actionable',
    );
  }

  TugboatViewportSemanticNode? _viewportSemanticNodeFromSemantics({
    required SemanticsNode node,
    required RenderBox rootRender,
    required Size viewport,
    required TugboatSceneInventory inventory,
  }) {
    if (node.isInvisible) return null;

    final data = node.getSemanticsData();
    if (data.rect.isEmpty) return null;

    final localRect = _semanticsRectInRootCoordinates(
      data.rect,
      rootRender: rootRender,
    );
    if (localRect.isEmpty) return null;

    final boundsNorm = TugboatNormalizedBounds.fromRect(localRect, viewport);
    if (boundsNorm.width <= 0 || boundsNorm.height <= 0) return null;
    if (!_boundsIntersectsViewport(boundsNorm)) return null;

    final actions = _semanticsActionsFromData(data);
    final role = _semanticsRoleFromData(data);
    final enabled = data.flagsCollection.isEnabled;
    final scrollable = _semanticsNodeIsScrollable(data);
    if (actions.isEmpty &&
        role == null &&
        !scrollable &&
        !data.flagsCollection.isHeader &&
        !data.flagsCollection.isImage &&
        !data.flagsCollection.isTextField) {
      return null;
    }

    final link = _linkInventoryToSemanticNode(
      role: role,
      actions: actions,
      boundsNorm: boundsNorm,
      inventory: inventory,
    );

    return TugboatViewportSemanticNode(
      nodeId: node.id,
      parentId: node.parent?.id,
      depth: node.depth,
      siblingIndex: node.indexInParent,
      role: role,
      actions: actions,
      enabled: enabled,
      boundsNorm: boundsNorm,
      scrollable: scrollable,
      linkedFingerprint: link?.fingerprint,
      linkedCanonicalPath: link?.canonicalPath,
    );
  }

  Rect _semanticsRectInRootCoordinates(Rect globalRect, {required RenderBox rootRender}) {
    final topLeft = rootRender.globalToLocal(globalRect.topLeft);
    final bottomRight = rootRender.globalToLocal(globalRect.bottomRight);
    return Rect.fromPoints(topLeft, bottomRight);
  }

  List<String> _semanticsActionsFromData(SemanticsData data) {
    final actions = <String>[];
    if (data.hasAction(SemanticsAction.tap)) actions.add('tap');
    if (data.hasAction(SemanticsAction.longPress)) actions.add('longPress');
    if (data.hasAction(SemanticsAction.scrollUp)) actions.add('scrollUp');
    if (data.hasAction(SemanticsAction.scrollDown)) actions.add('scrollDown');
    if (data.hasAction(SemanticsAction.scrollLeft)) actions.add('scrollLeft');
    if (data.hasAction(SemanticsAction.scrollRight)) actions.add('scrollRight');
    actions.sort();
    return actions;
  }

  String? _semanticsRoleFromData(SemanticsData data) {
    if (data.role != SemanticsRole.none) {
      return data.role.name;
    }
    if (data.flagsCollection.isButton) return 'button';
    if (data.flagsCollection.isLink) return 'link';
    if (data.flagsCollection.isTextField) return 'textField';
    if (data.flagsCollection.isImage) return 'image';
    if (data.flagsCollection.isHeader) return 'header';
    return null;
  }

  bool _semanticsNodeIsScrollable(SemanticsData data) {
    return data.flagsCollection.hasImplicitScrolling ||
        data.scrollExtentMax != null ||
        data.hasAction(SemanticsAction.scrollUp) ||
        data.hasAction(SemanticsAction.scrollDown) ||
        data.hasAction(SemanticsAction.scrollLeft) ||
        data.hasAction(SemanticsAction.scrollRight);
  }

  TugboatSceneInventoryEntry? _linkInventoryToSemanticNode({
    required String? role,
    required List<String> actions,
    required TugboatNormalizedBounds boundsNorm,
    required TugboatSceneInventory inventory,
  }) {
    TugboatSceneInventoryEntry? best;
    var bestOverlap = 0.0;
    for (final entry in inventory.elements) {
      final overlap = _boundsOverlapRatio(boundsNorm, entry.boundsNorm);
      if (overlap < 0.5) continue;
      if (!_inventoryRoleCompatible(role, entry.role)) continue;
      if (!_inventoryActionsCompatible(actions, entry.actions)) continue;
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = entry;
      }
    }
    return best;
  }

  bool _inventoryRoleCompatible(String? semanticRole, String? inventoryRole) {
    if (semanticRole == null || inventoryRole == null) return true;
    if (semanticRole == inventoryRole) return true;
    if (semanticRole == 'button' && inventoryRole == 'button') return true;
    if (semanticRole == 'display' && inventoryRole == 'display') return true;
    return semanticRole == 'button' || inventoryRole == 'button';
  }

  bool _inventoryActionsCompatible(
    List<String> semanticActions,
    List<String> inventoryActions,
  ) {
    if (semanticActions.isEmpty || inventoryActions.isEmpty) return true;
    return semanticActions.toSet().intersection(inventoryActions.toSet()).isNotEmpty;
  }

  double _boundsOverlapRatio(
    TugboatNormalizedBounds left,
    TugboatNormalizedBounds right,
  ) {
    final overlapLeft = left.left > right.left ? left.left : right.left;
    final overlapTop = left.top > right.top ? left.top : right.top;
    final overlapRight = (left.left + left.width) < (right.left + right.width)
        ? (left.left + left.width)
        : (right.left + right.width);
    final overlapBottom = (left.top + left.height) < (right.top + right.height)
        ? (left.top + left.height)
        : (right.top + right.height);
    final overlapWidth = overlapRight - overlapLeft;
    final overlapHeight = overlapBottom - overlapTop;
    if (overlapWidth <= 0 || overlapHeight <= 0) return 0;
    final overlapArea = overlapWidth * overlapHeight;
    final leftArea = left.width * left.height;
    if (leftArea <= 0) return 0;
    return overlapArea / leftArea;
  }

  bool _normalizedPointInBounds(
    double nx,
    double ny,
    TugboatNormalizedBounds bounds,
  ) {
    return nx >= bounds.left &&
        nx <= bounds.left + bounds.width &&
        ny >= bounds.top &&
        ny <= bounds.top + bounds.height;
  }

  bool _boundsIntersectsViewport(TugboatNormalizedBounds bounds) {
    return bounds.left < 1 &&
        bounds.top < 1 &&
        bounds.left + bounds.width > 0 &&
        bounds.top + bounds.height > 0;
  }

  TugboatViewportSemanticNode _pickViewportSemanticWinner(
    List<TugboatViewportSemanticNode> candidates,
  ) {
    final sorted = [...candidates]
      ..sort((left, right) {
        final leftArea = left.boundsNorm.width * left.boundsNorm.height;
        final rightArea = right.boundsNorm.width * right.boundsNorm.height;
        final areaCompare = leftArea.compareTo(rightArea);
        if (areaCompare != 0) return areaCompare;
        return right.depth.compareTo(left.depth);
      });
    return sorted.first;
  }

  TugboatViewportSemanticResolution _resolutionForNode({
    required TugboatViewportSemanticNode node,
    required String status,
  }) {
    return TugboatViewportSemanticResolution(
      status: status,
      nodeId: node.nodeId,
      role: node.role,
      actions: node.actions,
      boundsNorm: node.boundsNorm,
      linkedFingerprint: node.linkedFingerprint,
      enabled: node.enabled,
    );
  }

  Map<String, int> _viewportSemanticMapSummary(
    List<TugboatViewportSemanticNode> nodes,
  ) {
    var actionableCount = 0;
    var scrollableCount = 0;
    var disabledCount = 0;
    for (final node in nodes) {
      if (node.isActionable) actionableCount++;
      if (node.scrollable) scrollableCount++;
      if (node.enabled == false) disabledCount++;
    }
    return {
      'totalNodes': nodes.length,
      'actionableCount': actionableCount,
      'scrollableCount': scrollableCount,
      'disabledCount': disabledCount,
    };
  }

  String _viewportSemanticMapHash(List<TugboatViewportSemanticNode> nodes) {
    final parts = nodes.map((node) {
      final bounds = node.boundsNorm;
      return [
        node.nodeId,
        node.parentId ?? -1,
        node.depth,
        node.siblingIndex ?? -1,
        node.role ?? '',
        node.actions.join(','),
        node.enabled ?? true,
        bounds.left,
        bounds.top,
        bounds.width,
        bounds.height,
        node.scrollable,
        node.linkedFingerprint ?? '',
      ].join('|');
    }).toList();
    return tugboatLabelHash(parts.join('\n'));
  }
}
