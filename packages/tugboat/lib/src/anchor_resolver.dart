part of 'anchors.dart';

class _TokenMap {
  _TokenMap({
    required this.tokens,
    required this.retainedParents,
    required this.tagIds,
    required this.isActionable,
    required this.hasActionableDescendant,
    required this.hasTokenizedActionableDescendant,
    required this.isSensitive,
    required this.underActionable,
    required this.structuralRouteSignature,
    required this.renderElements,
    required this.hasBlockingOverlay,
    required this.hasDismissibleModalBarrier,
    required this.includedElements,
    required this.actionableSummary,
    required this.subLabel,
  });

  final Map<Element, String> tokens;
  final Map<Element, Element?> retainedParents;
  final Map<Element, String> tagIds;
  final Map<Element, bool> isActionable;
  final Map<Element, bool> hasActionableDescendant;
  final Map<Element, bool> hasTokenizedActionableDescendant;
  final Map<Element, bool> isSensitive;
  final Map<Element, bool> underActionable;
  final String structuralRouteSignature;
  final Map<RenderObject, Element> renderElements;
  final bool hasBlockingOverlay;
  final bool hasDismissibleModalBarrier;
  final Set<Element> includedElements;
  final Map<String, int> actionableSummary;
  final String? subLabel;
}

class _VisitAcc {
  const _VisitAcc({
    this.elements = const {},
    this.pendingBlocker = false,
    this.hasBlockingOverlay = false,
    this.hasActionableDescendant = false,
    this.hasTokenizedActionableDescendant = false,
  });

  final Set<Element> elements;
  final bool pendingBlocker;
  final bool hasBlockingOverlay;
  final bool hasActionableDescendant;
  final bool hasTokenizedActionableDescendant;
}

class _TokenMapChildState {
  _TokenMapChildState({required this.pendingBlocker});

  bool pendingBlocker;
  bool hasBlockingOverlay = false;
  bool hasActionable = false;
  bool hasTokenizedActionable = false;
  final Set<Element> elements = <Element>{};
}

class _TokenMapVisitor {
  _TokenMapVisitor(
    this.resolver,
    this.rootRender, {
    required this.tokens,
    required this.retainedParents,
    required this.tagIds,
    required this.isActionable,
    required this.hasActionableDescendant,
    required this.hasTokenizedActionableDescendant,
    required this.isSensitive,
    required this.underActionable,
    required this.ordinalCounters,
    required this.renderElements,
    required this.includedElements,
  });

  final AnchorResolver resolver;
  final RenderBox rootRender;
  final Map<Element, String> tokens;
  final Map<Element, Element?> retainedParents;
  final Map<Element, String> tagIds;
  final Map<Element, bool> isActionable;
  final Map<Element, bool> hasActionableDescendant;
  final Map<Element, bool> hasTokenizedActionableDescendant;
  final Map<Element, bool> isSensitive;
  final Map<Element, bool> underActionable;
  final Map<Object, int> ordinalCounters;
  final Map<RenderObject, Element> renderElements;
  final Set<Element> includedElements;
  String? subLabel;
  bool rootHasBlockingOverlay = false;
  bool hasDismissibleModalBarrier = false;

  _VisitAcc visit(
    Element element,
    Element? retainedParent,
    bool inList,
    int? listItemIndex,
    bool sensitive,
    bool underActionable,
  ) {
    final widget = element.widget;
    final renderObject = element.renderObject;
    final effectiveListItemIndex = _effectiveListItemIndex(
      widget,
      inList,
      listItemIndex,
    );
    _noteDismissibleModalBarrier(widget);
    if (_shouldSkip(widget, renderObject)) return const _VisitAcc();
    _noteElement(element, widget, renderObject, sensitive, underActionable);
    final candidate = _candidateFor(
      element,
      retainedParent,
      inList,
      effectiveListItemIndex,
      sensitive,
      underActionable,
    );
    final children = _visitChildren(element, candidate);
    return _completeVisit(element, children, candidate.elementIsActionable);
  }

  bool _shouldSkip(Widget widget, RenderObject? renderObject) =>
      tugboatHidesSubtree(widget) ||
      widget is TugboatInternal ||
      tugboatHidesRenderObject(renderObject) ||
      _excludesSemantics(renderObject);

  bool _excludesSemantics(RenderObject? renderObject) =>
      renderObject is RenderExcludeSemantics && renderObject.excluding;

  int? _effectiveListItemIndex(
    Widget widget,
    bool inList,
    int? listItemIndex,
  ) => inList && widget is IndexedSemantics ? widget.index : listItemIndex;

  void _noteDismissibleModalBarrier(Widget widget) {
    if (widget is ModalBarrier && widget.dismissible) {
      hasDismissibleModalBarrier = true;
    }
  }

  void _noteElement(
    Element element,
    Widget widget,
    RenderObject? renderObject,
    bool sensitive,
    bool actionable,
  ) {
    final elementSensitive = sensitive || widget is TugboatSensitive;
    isSensitive[element] = elementSensitive;
    underActionable[element] = actionable;
    if (renderObject != null) renderElements[renderObject] = element;
    if (widget is TugboatSubView && subLabel == null) subLabel = widget.label;
  }

  ({
    Element? retainedParent,
    bool elementIsActionable,
    bool childInList,
    int? listItemIndex,
    bool isSensitive,
    bool childUnderActionable,
  })
  _candidateFor(
    Element element,
    Element? retainedParent,
    bool inList,
    int? listItemIndex,
    bool sensitive,
    bool underActionable,
  ) {
    final widget = element.widget;
    final elementSensitive = sensitive || widget is TugboatSensitive;
    final retainable = resolver._isRetainable(element, rootRender);
    final role = retainable ? tugboatRoleForWidget(widget) : null;
    final retainType = _retainType(widget, retainable, role);
    final tokenized = _recordCandidateToken(
      element,
      retainedParent,
      inList,
      listItemIndex,
      retainType,
    );
    final elementIsActionable =
        role != null && role.enabled != false && tokens.containsKey(element);
    if (elementIsActionable) isActionable[element] = true;
    return (
      retainedParent: tokenized.parent,
      elementIsActionable: elementIsActionable,
      childInList: tokenized.emittedListItem
          ? false
          : inList || resolver._isListContainer(widget),
      listItemIndex: tokenized.emittedListItem ? null : listItemIndex,
      isSensitive: elementSensitive,
      childUnderActionable:
          underActionable || tugboatIsActionableWidget(widget),
    );
  }

  String? _retainType(Widget widget, bool retainable, dynamic role) =>
      retainable
      ? resolver._canonicalType(widget) ??
            (role != null && role.enabled != false
                ? resolver._actionableTypeName(widget)
                : null)
      : null;

  ({Element? parent, bool emittedListItem}) _recordCandidateToken(
    Element element,
    Element? retainedParent,
    bool inList,
    int? listItemIndex,
    String? retainType,
  ) {
    if (retainType == null) {
      return (parent: retainedParent, emittedListItem: false);
    }
    final token = inList
        ? _listItemToken(retainedParent, listItemIndex)
        : _ordinalToken(element, retainedParent, retainType);
    tokens[element] = token;
    retainedParents[element] = retainedParent;
    return (parent: element, emittedListItem: inList);
  }

  String _listItemToken(Element? retainedParent, int? listItemIndex) {
    final counterKey = Object.hash(retainedParent, '[item]');
    final fallbackOrdinal = ordinalCounters[counterKey] ?? 0;
    ordinalCounters[counterKey] = fallbackOrdinal + 1;
    return '[item:${listItemIndex ?? fallbackOrdinal}]';
  }

  String _ordinalToken(Element element, Element? parent, String retainType) {
    final counterKey = Object.hash(parent, retainType);
    final ordinal = ordinalCounters[counterKey] ?? 0;
    ordinalCounters[counterKey] = ordinal + 1;
    final tagId = resolver._tagIdFromWidget(element.widget);
    if (tagId != null) tagIds[element] = tagId;
    return '$retainType#$ordinal';
  }

  _TokenMapChildState _visitChildren(
    Element element,
    ({
      Element? retainedParent,
      bool elementIsActionable,
      bool childInList,
      int? listItemIndex,
      bool isSensitive,
      bool childUnderActionable,
    })
    candidate,
  ) {
    final renderObject = element.renderObject;
    final state = _TokenMapChildState(
      pendingBlocker:
          renderObject is RenderBlockSemantics && renderObject.blocking,
    );
    element.visitChildElements((child) {
      final childListItemIndex = _childListItemIndex(
        element,
        child,
        candidate.childInList,
        candidate.listItemIndex,
      );
      _absorbChild(
        element,
        state,
        visit(
          child,
          candidate.retainedParent,
          candidate.childInList,
          childListItemIndex,
          candidate.isSensitive,
          candidate.childUnderActionable,
        ),
      );
    });
    return state;
  }

  int? _childListItemIndex(
    Element element,
    Element child,
    bool childInList,
    int? inheritedIndex,
  ) {
    if (!childInList || element is! SliverMultiBoxAdaptorElement) {
      return inheritedIndex;
    }
    final slot = child.slot;
    return slot is int && slot >= 0 ? slot : inheritedIndex;
  }

  void _absorbChild(
    Element element,
    _TokenMapChildState state,
    _VisitAcc child,
  ) {
    if (child.pendingBlocker && resolver._isOverlayLevel(element)) {
      _replaceWithBlockingChild(element, child, state);
    }
    state.elements.addAll(child.elements);
    state.pendingBlocker = state.pendingBlocker || child.pendingBlocker;
    state.hasBlockingOverlay =
        state.hasBlockingOverlay || child.hasBlockingOverlay;
    state.hasActionable = state.hasActionable || child.hasActionableDescendant;
    state.hasTokenizedActionable =
        state.hasTokenizedActionable || child.hasTokenizedActionableDescendant;
  }

  void _replaceWithBlockingChild(
    Element element,
    _VisitAcc child,
    _TokenMapChildState state,
  ) {
    state.elements
      ..clear()
      ..add(element);
    _removeShadowedElements(element, child.elements);
    state.pendingBlocker = false;
    state.hasBlockingOverlay = true;
    rootHasBlockingOverlay = true;
  }

  void _removeShadowedElements(Element element, Set<Element> childElements) {
    for (final previous in [...includedElements]) {
      if (!identical(previous, element)) includedElements.remove(previous);
    }
    _removeShadowedMapEntries(element, childElements);
    _removeShadowedRenderEntries(element, childElements);
  }

  void _removeShadowedMapEntries(Element element, Set<Element> childElements) {
    for (final key in [...tokens.keys]) {
      if (identical(key, element) || childElements.contains(key)) continue;
      tokens.remove(key);
      retainedParents.remove(key);
      tagIds.remove(key);
      isActionable.remove(key);
      hasActionableDescendant.remove(key);
      hasTokenizedActionableDescendant.remove(key);
      isSensitive.remove(key);
      underActionable.remove(key);
    }
  }

  void _removeShadowedRenderEntries(
    Element element,
    Set<Element> childElements,
  ) {
    for (final entry in [...renderElements.entries]) {
      if (!identical(entry.value, element) &&
          !childElements.contains(entry.value)) {
        renderElements.remove(entry.key);
      }
    }
  }

  _VisitAcc _completeVisit(
    Element element,
    _TokenMapChildState children,
    bool elementIsActionable,
  ) {
    if (children.hasBlockingOverlay) rootHasBlockingOverlay = true;
    includedElements.add(element);
    includedElements.addAll(children.elements);
    final actionable = _hasActionableChild(
      children.elements,
      children.hasActionable,
    );
    final tokenized = _hasTokenizedActionableChild(
      children.elements,
      children.hasTokenizedActionable,
    );
    hasActionableDescendant[element] = actionable;
    hasTokenizedActionableDescendant[element] = tokenized;
    return _VisitAcc(
      elements: {element, ...children.elements},
      pendingBlocker: children.pendingBlocker,
      hasBlockingOverlay: children.hasBlockingOverlay,
      hasActionableDescendant: actionable || elementIsActionable,
      hasTokenizedActionableDescendant: tokenized || elementIsActionable,
    );
  }

  bool _hasActionableChild(Set<Element> children, bool hasActionable) =>
      hasActionable || children.any((child) => isActionable[child] == true);

  bool _hasTokenizedActionableChild(Set<Element> children, bool hasTokenized) =>
      hasTokenized ||
      children.any(
        (child) => isActionable[child] == true && tokens.containsKey(child),
      );
}

/// Builds target anchors from hit-test results.
class AnchorResolver {
  AnchorResolver({required this.rootKey, this.widgetNames = const {}});

  final GlobalKey rootKey;
  final Map<Type, String> widgetNames;

  _TokenMap? _cachedTokenMap;
  int? _cachedFrameId;
  RenderBox? _cachedRootRender;
  @visibleForTesting
  int debugTokenMapBuildCount = 0;
  int get tokenMapBuildCount => debugTokenMapBuildCount;
  int _frameEpoch = 0;
  bool _frameCallbackScheduled = false;

  void invalidateTokenMapCache() {
    _cachedTokenMap = null;
    _cachedFrameId = null;
    _cachedRootRender = null;
  }

  /// Collects screenshot mask rectangles using a frame-scoped token map when
  /// available, avoiding a second full element walk.
  List<Rect> collectMaskRects({
    required RenderBox rootRender,
    required bool Function(
      Element element,
      Widget widget,
      RenderBox renderObject,
      bool explicitlySensitive,
      bool actionable,
    )
    shouldMask,
  }) {
    final rootContext = rootKey.currentContext;
    if (rootContext is! Element) return const [];
    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) return const [];

    final masks = <Rect>[];
    final maskedRenderObjects = <RenderObject>{};
    for (final element in tokenMap.includedElements) {
      _addMaskRect(
        element,
        tokenMap,
        rootRender,
        shouldMask,
        maskedRenderObjects,
        masks,
      );
    }
    return masks;
  }

  void _addMaskRect(
    Element element,
    _TokenMap tokenMap,
    RenderBox rootRender,
    bool Function(Element, Widget, RenderBox, bool, bool) shouldMask,
    Set<RenderObject> maskedRenderObjects,
    List<Rect> masks,
  ) {
    final widget = element.widget;
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return;
    }
    final sensitive = tokenMap.isSensitive[element] == true;
    final actionable =
        tokenMap.underActionable[element] == true ||
        tugboatIsActionableWidget(widget);
    if (!shouldMask(element, widget, renderObject, sensitive, actionable)) {
      return;
    }
    if (!maskedRenderObjects.add(renderObject)) return;
    try {
      final transformed = MatrixUtils.transformRect(
        renderObject.getTransformTo(rootRender),
        renderObject.paintBounds,
      );
      final rect = transformed.intersect(rootRender.paintBounds);
      if (rect.width > 0 && rect.height > 0) masks.add(rect);
    } catch (_) {
      // Detached render object can race capture; omit its mask safely.
    }
  }

  void _scheduleFrameCacheInvalidation() {
    if (_frameCallbackScheduled) return;
    _frameCallbackScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _frameCallbackScheduled = false;
      _frameEpoch++;
      _cachedTokenMap = null;
      _cachedFrameId = null;
      _cachedRootRender = null;
    });
  }

  _TokenMap? _tokenMapFor(Element rootContext, RenderBox rootRender) {
    // Reuse within the current frame when the root render object is unchanged.
    if (_cachedTokenMap != null &&
        _cachedFrameId == _frameEpoch &&
        identical(_cachedRootRender, rootRender)) {
      return _cachedTokenMap;
    }
    final built = _buildTokenMap(rootContext, rootRender);
    _cachedTokenMap = built;
    _cachedFrameId = _frameEpoch;
    _cachedRootRender = rootRender;
    _scheduleFrameCacheInvalidation();
    return built;
  }

  TugboatTargetAnchor? targetAt(Offset globalPosition, {String? route}) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootRender is! RenderBox || rootContext is! Element) return null;

    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) return null;
    return _targetAtWithTokenMap(
      globalPosition,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
    );
  }

  /// Builds inventory and resolves a tap target from one token-map walk.
  ({
    TugboatSceneInventory? inventory,
    TugboatTargetAnchor? target,
    bool tapHitsDismissibleBarrier,
  })
  buildTapContext({
    required Offset tapPosition,
    required String? route,
    required bool keyboardOpen,
    required bool modalOpen,
    required bool detectDismissibleBarrier,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootRender is! RenderBox || rootContext is! Element) {
      return (inventory: null, target: null, tapHitsDismissibleBarrier: false);
    }

    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) {
      return (inventory: null, target: null, tapHitsDismissibleBarrier: false);
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
    );
    target = _snapPathlessTargetToInventory(
      target: target,
      inventory: inventory,
      tapPosition: tapPosition,
      rootRender: rootRender,
    );
    target = _normalizeTargetToInventory(target: target, inventory: inventory);
    inventory = _injectTapTargetIntoInventory(
      inventory: inventory,
      target: target,
      tapPosition: tapPosition,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
    );
    return (
      inventory: inventory,
      target: target,
      tapHitsDismissibleBarrier:
          detectDismissibleBarrier &&
          (modalOpen || tokenMap.hasDismissibleModalBarrier) &&
          _tapHitsDismissibleModalBarrier(
            rootRender: rootRender,
            tapPosition: tapPosition,
            tokenMap: tokenMap,
          ),
    );
  }

  bool _tapHitsDismissibleModalBarrier({
    required RenderBox rootRender,
    required Offset tapPosition,
    required _TokenMap tokenMap,
  }) {
    final result = BoxHitTestResult();
    rootRender.hitTest(result, position: rootRender.globalToLocal(tapPosition));
    for (final hit in result.path) {
      if (hit.target is! RenderObject) continue;
      final element = tokenMap.renderElements[hit.target as RenderObject];
      if (element == null) continue;
      if (element.widget is ModalBarrier &&
          (element.widget as ModalBarrier).dismissible) {
        return true;
      }
      var found = false;
      element.visitAncestorElements((ancestor) {
        final widget = ancestor.widget;
        if (widget is ModalBarrier && widget.dismissible) {
          found = true;
          return false;
        }
        return true;
      });
      if (found) return true;
    }
    return false;
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

    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) return null;
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
    final localPosition = rootRender.globalToLocal(globalPosition);
    rootRender.hitTest(result, position: localPosition);

    TugboatTargetAnchor? roleOnly;
    TugboatTargetAnchor? fallback;
    for (final entry in result.path) {
      if (entry.target is! RenderObject) continue;
      final element = tokenMap.renderElements[entry.target as RenderObject];
      if (element == null || tugboatIsCaptureChrome(element.widget)) continue;

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
      final widgetRole = tugboatRoleForWidget(widget);
      if (widgetRole != null) {
        role ??= widgetRole.name;
        enabled ??= widgetRole.enabled;
        actions.addAll(widgetRole.actions);
        boundsElement ??= element;
        widgetType ??= _widgetName(widget);
        fingerprintElement ??= element;
      } else if (widgetType == null && !tugboatIsCaptureChrome(widget)) {
        widgetType = _widgetName(widget);
      }
    }

    inspectElement(hitElement);
    hitElement.visitAncestorElements((ancestor) {
      inspectElement(ancestor);
      return true;
    });

    final anchorElement = boundsElement ?? hitElement;

    final bounds = _rawBoundsForElement(anchorElement, rootRender);

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

    // A structural list position keeps sibling controls distinct without
    // making visible copy or icon data part of their identity.
    final hasItemPosition = _hasInheritedItemPosition(fpElement, tokenMap);
    final pathConfidence = hasItemPosition ? 'medium' : 'low';

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

  Rect? _rawBoundsForElement(Element element, RenderBox rootRender) {
    final render = element.renderObject;
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    try {
      return MatrixUtils.transformRect(
        render.getTransformTo(rootRender),
        render.paintBounds,
      );
    } catch (_) {
      return null;
    }
  }

  _TokenMap _buildTokenMap(Element rootElement, RenderBox rootRender) {
    debugTokenMapBuildCount++;
    final tokens = <Element, String>{};
    final retainedParents = <Element, Element?>{};
    final tagIds = <Element, String>{};
    final isActionable = <Element, bool>{};
    final hasActionableDescendant = <Element, bool>{};
    final hasTokenizedActionableDescendant = <Element, bool>{};
    final isSensitiveMap = <Element, bool>{};
    final underActionableMap = <Element, bool>{};
    final ordinalCounters = <Object, int>{};
    final renderElements = <RenderObject, Element>{};
    final includedElements = <Element>{};
    final visitor = _TokenMapVisitor(
      this,
      rootRender,
      tokens: tokens,
      retainedParents: retainedParents,
      tagIds: tagIds,
      isActionable: isActionable,
      hasActionableDescendant: hasActionableDescendant,
      hasTokenizedActionableDescendant: hasTokenizedActionableDescendant,
      isSensitive: isSensitiveMap,
      underActionable: underActionableMap,
      ordinalCounters: ordinalCounters,
      renderElements: renderElements,
      includedElements: includedElements,
    );

    _VisitAcc visit(
      Element element,
      Element? retainedParent,
      bool inList,
      int? listItemIndex,
      bool sensitive,
      bool underActionable,
    ) {
      return visitor.visit(
        element,
        retainedParent,
        inList,
        listItemIndex,
        sensitive,
        underActionable,
      );
    }

    // Visit the full element tree (not only onstage) so OverlayPortal/Tooltip
    // subtrees stay addressable for hit testing, matching pre-merge inclusion.
    rootElement.visitChildElements(
      (child) => visit(child, null, false, null, false, false),
    );
    // Always include the capture root so hit mapping stays consistent.
    includedElements.add(rootElement);

    final actionableSummary = <String, int>{};
    final actionablePaths = <String>{};
    for (final element in includedElements) {
      if (isActionable[element] != true || !tokens.containsKey(element)) {
        continue;
      }
      if (hasActionableDescendant[element] == true) continue;
      final role = tugboatRoleForWidget(element.widget);
      if (role == null || role.enabled == false) continue;
      actionableSummary[role.name] = (actionableSummary[role.name] ?? 0) + 1;
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
      isActionable: isActionable,
      hasActionableDescendant: hasActionableDescendant,
      hasTokenizedActionableDescendant: hasTokenizedActionableDescendant,
      isSensitive: isSensitiveMap,
      underActionable: underActionableMap,
      structuralRouteSignature: structuralRouteSignature,
      renderElements: renderElements,
      hasBlockingOverlay: visitor.rootHasBlockingOverlay,
      hasDismissibleModalBarrier: visitor.hasDismissibleModalBarrier,
      includedElements: includedElements,
      actionableSummary: actionableSummary,
      subLabel: visitor.subLabel,
    );
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

  /// Whether [element] or a retained ancestor has a structural item position.
  bool _hasInheritedItemPosition(Element element, _TokenMap tokenMap) {
    Element? current = element;
    while (current != null) {
      if (tokenMap.tokens[current]?.startsWith('[item:') == true) return true;
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

  String? _normalizedWidgetTypeName(Widget widget) {
    if (tugboatIsCaptureChrome(widget)) return null;
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

  String _normalizeItemPathForSignature(String path) {
    return path.replaceAll(RegExp(r'\[item:[^\]]+\]'), '[item]');
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
}
