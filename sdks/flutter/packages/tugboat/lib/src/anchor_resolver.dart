part of 'anchors.dart';

class _TokenMap {
  _TokenMap({
    required this.root,
    required this.rootRender,
    required this.legacy,
    required this.tokens,
    required this.retainedParents,
    required this.tagIds,
    required this.isActionable,
    required this.hasActionableDescendant,
    required this.hasTokenizedActionableDescendant,
    required this.isSensitive,
    required this.structuralRouteSignature,
    required this.renderElements,
    required this.hasBlockingOverlay,
    required this.hasDismissibleModalBarrier,
    required this.includedElements,
    required this.actionableSummary,
    required this.subLabel,
    required this.controlCandidates,
    required this.newRoleCandidates,
    required this.identityAncestors,
    this.excludedSemantics = const [],
  });

  final Element root;
  final RenderBox rootRender;

  /// True for the schema 6 walk kept only to compute `aliases`.
  final bool legacy;
  final Map<Element, String> tokens;
  final Map<Element, Element?> retainedParents;
  final Map<Element, String> tagIds;
  final Map<Element, bool> isActionable;
  final Map<Element, bool> hasActionableDescendant;
  final Map<Element, bool> hasTokenizedActionableDescendant;
  final Map<Element, bool> isSensitive;
  final String structuralRouteSignature;
  final Map<RenderObject, Element> renderElements;
  final bool hasBlockingOverlay;
  final bool hasDismissibleModalBarrier;
  final Set<Element> includedElements;
  final Map<String, int> actionableSummary;
  final String? subLabel;

  /// Elements that name a control whatever their enabled state: a schema 6
  /// role, or a control whose callbacks were removed (stand-in gesture).
  final Set<Element> controlCandidates;

  /// Schema 7 low-level roles (see [tugboatInteractiveRoleForWidget]) that sit
  /// outside every control and enclose no control.
  final Set<Element> newRoleCandidates;

  /// Retained ancestors of the tokenized control and low-level candidates.
  /// A candidate outside this set is a leaf identity.
  final Set<Element> identityAncestors;

  /// Roots of the visible subtrees skipped only because they exclude
  /// semantics (`Semantics(label) > ExcludeSemantics > button`). Exploration
  /// inventories look for the one control such a subtree hides.
  final List<Element> excludedSemantics;

  /// The schema 6 walk of this same tree, built on first use for aliases.
  _TokenMap? legacyMap;

  /// [excludedSemantics] by their `RenderExcludeSemantics`, built on first use.
  late final Map<RenderObject, Element> excludedByRender = {
    for (final excluded in excludedSemantics)
      if (excluded.renderObject != null) excluded.renderObject!: excluded,
  };

  /// The sheet or dialog widget class of this tree, computed once.
  bool surfaceClassKnown = false;
  String? surfaceClass;

  bool isIdentityCandidate(Element element) =>
      controlCandidates.contains(element) ||
      newRoleCandidates.contains(element);
}

/// How an element takes part in control identity. A [control] is a schema 6
/// role (enabled or not) or a gesture stand-in inside a disabled one; a
/// [lowLevel] element has a schema 7 role, and is a control of its own only
/// when it is in [_TokenMap.newRoleCandidates].
enum _IdentityKind { none, control, lowLevel }

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
    required this.legacy,
    required this.controlCandidates,
    required this.newRoleCandidates,
    required this.tokens,
    required this.retainedParents,
    required this.tagIds,
    required this.isActionable,
    required this.hasActionableDescendant,
    required this.hasTokenizedActionableDescendant,
    required this.isSensitive,
    required this.ordinalCounters,
    required this.renderElements,
    required this.includedElements,
  });

  final AnchorResolver resolver;
  final RenderBox rootRender;
  final bool legacy;
  final Set<Element> controlCandidates;
  final Set<Element> newRoleCandidates;
  final Map<Element, String> tokens;
  final Map<Element, Element?> retainedParents;
  final Map<Element, String> tagIds;
  final Map<Element, bool> isActionable;
  final Map<Element, bool> hasActionableDescendant;
  final Map<Element, bool> hasTokenizedActionableDescendant;
  final Map<Element, bool> isSensitive;
  final Map<Object, int> ordinalCounters;
  final Map<RenderObject, Element> renderElements;
  final Set<Element> includedElements;
  String? subLabel;
  bool rootHasBlockingOverlay = false;
  bool hasDismissibleModalBarrier = false;
  final List<Element> excludedSemantics = <Element>[];

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
    if (_shouldSkip(widget, renderObject)) {
      if (_onlyExcludesSemantics(widget, renderObject)) {
        excludedSemantics.add(element);
      }
      return const _VisitAcc();
    }
    _noteElement(element, widget, renderObject, sensitive);
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

  /// Skipped for excluding semantics alone: not hidden, offstage or SDK-owned.
  bool _onlyExcludesSemantics(Widget widget, RenderObject? renderObject) =>
      !legacy &&
      _excludesSemantics(renderObject) &&
      !tugboatHidesSubtree(widget) &&
      widget is! TugboatInternal &&
      !tugboatHidesRenderObject(renderObject);

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
  ) {
    final elementSensitive = sensitive || widget is TugboatSensitive;
    isSensitive[element] = elementSensitive;
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
    _noteIdentity(element);
    final role = retainable ? resolver._roleOf(element, legacy: legacy) : null;
    final retainType = _retainType(element, widget, retainable, role);
    final tokenized = _recordCandidateToken(
      element,
      retainedParent,
      inList,
      listItemIndex,
      retainType,
    );
    final elementIsActionable = _isActionableToken(element, role);
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

  /// Records [element] as a control candidate or, for a schema 7 low-level
  /// role outside every control and around no control, as a low-level
  /// candidate.
  void _noteIdentity(Element element) {
    switch (resolver._identityKindOf(element, legacy: legacy)) {
      case _IdentityKind.control:
        controlCandidates.add(element);
      case _IdentityKind.lowLevel:
        if (resolver._isOwnLowLevelControl(element)) {
          newRoleCandidates.add(element);
        }
      case _IdentityKind.none:
        break;
    }
  }

  /// A retained control keeps its token whether or not it is enabled, so a
  /// disabled control and its enabled twin share one path (schema 7). The
  /// schema 6 walk kept a denylisted role only while it was enabled.
  /// A low-level role only makes an element actionable when it is an identity
  /// of its own (outside every control).
  bool _isActionableToken(Element element, WidgetRole? role) {
    if (role == null || role.enabled == false) return false;
    if (!tokens.containsKey(element)) return false;
    return legacy ||
        tugboatRoleForWidget(element.widget) != null ||
        newRoleCandidates.contains(element);
  }

  String? _retainType(
    Element element,
    Widget widget,
    bool retainable,
    WidgetRole? role,
  ) {
    if (!retainable) return null;
    final canonical = resolver._canonicalType(widget, legacy: legacy);
    if (canonical != null) return canonical;
    if (role == null) return null;
    if (legacy && role.enabled == false) return null;
    // A low-level role inside a control is plumbing of that control (a tap
    // Semantics in an InkWell): it keeps no segment of its own.
    if (!legacy && !newRoleCandidates.contains(element)) {
      final lowLevel = tugboatRoleForWidget(widget) == null;
      if (lowLevel) return null;
    }
    return resolver._actionableTypeName(widget);
  }

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
    if (!inList && _isLeafToken(element)) {
      return _recordLeafToken(element, retainedParent, retainType);
    }
    final token = inList
        ? _listItemToken(retainedParent, listItemIndex)
        : _ordinalToken(element, retainedParent, retainType);
    tokens[element] = token;
    retainedParents[element] = retainedParent;
    return (parent: element, emittedListItem: inList);
  }

  /// A low-level control of its own that schema 6 did not retain (a tap
  /// `Semantics`, a pointer-up `Listener`; a `RawGestureDetector` was always
  /// retained) gets a path for itself but is no retained parent, so the paths
  /// below it stay as in schema 6 whether or not its callback is set. In a
  /// list it takes the row's `[item:N]` position instead (and is a parent),
  /// because an ordinal would follow which rows happen to be built.
  bool _isLeafToken(Element element) =>
      !legacy &&
      newRoleCandidates.contains(element) &&
      resolver._canonicalType(element.widget, legacy: true) == null;

  ({Element? parent, bool emittedListItem}) _recordLeafToken(
    Element element,
    Element? retainedParent,
    String retainType,
  ) {
    tokens[element] = _ordinalToken(element, retainedParent, retainType);
    retainedParents[element] = retainedParent;
    return (parent: retainedParent, emittedListItem: false);
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

  /// Collects screenshot mask rectangles with the pixels-only [_MaskWalk].
  ///
  /// It does not share the identity token map: that walk prunes excluded
  /// semantics, content behind modal routes and [TugboatInternal], all of which
  /// are still painted. Throws when the root is gone or a rect cannot be
  /// computed, so the capture fails instead of sending an unmasked frame.
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
    if (rootContext is! Element) {
      throw StateError('Mask walk has no mounted capture root.');
    }
    final walk = _MaskWalk(rootRender, shouldMask)..run(rootContext);
    return walk.masks;
  }

  /// Order-sensitive signature of the visible structure in the current frame.
  ///
  /// It combines retained structural tokens, control state (see
  /// [tugboatControlStateSignature] and [ToggleableStateMixin.value]),
  /// blocking-overlay presence, and the
  /// rounded bounds of text, editable, and image boxes. It never reads text,
  /// semantics labels, or image pixels, and it is never serialized: capture
  /// uses it only to refuse perceptual (dHash) coalescing when the tree
  /// changed, for example when masked error text appears. Returns null when
  /// no token map is available for [rootRender].
  int? structureSignature({required RenderBox rootRender}) {
    final rootContext = rootKey.currentContext;
    if (rootContext is! Element) return null;
    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) return null;
    final parts = <Object?>[tokenMap.hasBlockingOverlay];
    for (final element in tokenMap.includedElements) {
      _addStructureParts(element, tokenMap, rootRender, parts);
    }
    return Object.hashAll(parts);
  }

  void _addStructureParts(
    Element element,
    _TokenMap tokenMap,
    RenderBox rootRender,
    List<Object?> parts,
  ) {
    final token = tokenMap.tokens[element];
    if (token != null) {
      parts
        ..add(token)
        ..add(tugboatControlStateSignature(element.widget));
    }
    if (element is StatefulElement) {
      final state = element.state;
      // Covers radios whose selection lives in a RadioGroup ancestor, and the
      // inner toggles of list tiles, without reading any label.
      if (state is ToggleableStateMixin) parts.add(state.value);
    }
    if (element is! RenderObjectElement) return;
    final renderObject = element.renderObject;
    if (renderObject is RenderParagraph ||
        renderObject is RenderEditable ||
        renderObject is RenderImage) {
      parts
        ..add(renderObject.runtimeType)
        ..add(_roundedContentBounds(renderObject as RenderBox, rootRender));
    }
  }

  Object? _roundedContentBounds(RenderBox renderObject, RenderBox rootRender) {
    if (!renderObject.attached || !renderObject.hasSize) return null;
    try {
      final rect = MatrixUtils.transformRect(
        renderObject.getTransformTo(rootRender),
        renderObject.paintBounds,
      );
      return Object.hash(
        rect.left.round(),
        rect.top.round(),
        rect.width.round(),
        rect.height.round(),
      );
    } catch (_) {
      // Detached render object can race capture; treat bounds as unknown.
      return null;
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

  /// The render objects under [globalPosition], deepest first: one plain hit
  /// test, no token-map walk.
  ///
  /// Taken at pointer-down so [buildTapContext] can still resolve the pressed
  /// control when the tap's own handler navigates. A push or pop makes the
  /// Navigator absorb pointers at once, and the SDK reads the tap after the
  /// app's recognizer has run, so a fresh hit test at pointer-up can no longer
  /// reach the old screen.
  List<HitTestTarget> hitPathAt(Offset globalPosition) {
    final rootRender = rootKey.currentContext?.findRenderObject();
    if (rootRender is! RenderBox || !rootRender.attached) return const [];
    final result = BoxHitTestResult();
    rootRender.hitTest(
      result,
      position: rootRender.globalToLocal(globalPosition),
    );
    return _hitTargets(result);
  }

  static List<HitTestTarget> _hitTargets(BoxHitTestResult result) => [
    for (final entry in result.path) entry.target,
  ];

  /// Builds inventory and resolves a tap target from one token-map walk.
  ///
  /// [pressedHitPath] is the hit path taken at pointer-down ([hitPathAt]). It
  /// is used only when the hit test now finds no actionable target with a
  /// path, so a tap that resolves today resolves exactly as before. It is
  /// resolved under [pressedRoute], the route the pointer went down on: a
  /// navigating `onTap` has already moved the current route to the
  /// destination, and the route key is part of the fingerprint.
  ///
  /// [routeChangedSincePress] says the route changed between pointer-down and
  /// now. The fresh hit test then sees the destination, not the control that
  /// was tapped, so a usable pressed target wins even when the fresh one is
  /// actionable and has a path. Without it a navigating tap could carry a
  /// destination control's fingerprint.
  ///
  /// `targetSource` and `targetRouteKey` report how the target was resolved
  /// and the route key its fingerprint was hashed under.
  ({
    TugboatSceneInventory? inventory,
    TugboatTargetAnchor? target,
    TugboatTargetResolutionSource? targetSource,
    String? targetRouteKey,
    bool tapHitsDismissibleBarrier,
  })
  buildTapContext({
    required Offset tapPosition,
    required String? route,
    required bool keyboardOpen,
    required bool modalOpen,
    required bool detectDismissibleBarrier,
    List<HitTestTarget>? pressedHitPath,
    String? pressedRoute,
    bool routeChangedSincePress = false,
    String? surfaceKind,
    bool withBoundsEvidence = false,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootRender is! RenderBox || rootContext is! Element) {
      return _emptyTapContext;
    }

    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) return _emptyTapContext;

    final resolved = _resolveTapTarget(
      tapPosition,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
      pressedHitPath: pressedHitPath,
      pressedRoute: pressedRoute,
      routeChangedSincePress: routeChangedSincePress,
      surface: _surfaceFor(tokenMap, kind: surfaceKind),
      withBoundsEvidence: withBoundsEvidence,
    );
    return (
      inventory: resolved.inventory,
      target: resolved.target,
      targetSource: resolved.source,
      targetRouteKey: resolved.routeKey,
      tapHitsDismissibleBarrier: _tapHitsBarrier(
        detect: detectDismissibleBarrier,
        modalOpen: modalOpen,
        tapPosition: tapPosition,
        rootRender: rootRender,
        tokenMap: tokenMap,
      ),
    );
  }

  bool _tapHitsBarrier({
    required bool detect,
    required bool modalOpen,
    required Offset tapPosition,
    required RenderBox rootRender,
    required _TokenMap tokenMap,
  }) {
    if (!detect) return false;
    if (!modalOpen && !tokenMap.hasDismissibleModalBarrier) return false;
    return _tapHitsDismissibleModalBarrier(
      rootRender: rootRender,
      tapPosition: tapPosition,
      tokenMap: tokenMap,
    );
  }

  /// Hit-tests the tap, builds the inventory and re-anchors the target to it
  /// (snap, then alias normalisation), tracking which route key the final
  /// fingerprint was hashed under.
  ({
    TugboatSceneInventory? inventory,
    TugboatTargetAnchor? target,
    TugboatTargetResolutionSource? source,
    String? routeKey,
  })
  _resolveTapTarget(
    Offset tapPosition, {
    required String? route,
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required List<HitTestTarget>? pressedHitPath,
    required String? pressedRoute,
    required bool routeChangedSincePress,
    required TugboatSurface surface,
    required bool withBoundsEvidence,
  }) {
    final hit = _hitTapTarget(
      tapPosition,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
      pressedHitPath: pressedHitPath,
      pressedRoute: pressedRoute,
      routeChangedSincePress: routeChangedSincePress,
    );
    var inventory = _buildSceneInventoryFromTokenMap(
      tokenMap: tokenMap,
      rootRender: rootRender,
      route: route,
      surface: surface,
      withBoundsEvidence: withBoundsEvidence,
    );
    final snapped = _snapPathlessTargetToInventory(
      target: hit.target,
      inventory: inventory,
      tapPosition: tapPosition,
      rootRender: rootRender,
    );
    // A control the pointer went down on inside a scrollable that stopped
    // taking pointers is not re-anchored: the inventory built now sees the
    // scrollable over it and lists the control as one of its aliases.
    final normalized = hit.pressedInsideScrollable
        ? snapped
        : _normalizeTargetToInventory(target: snapped, inventory: inventory);
    inventory = _injectTapTargetIntoInventory(
      inventory: inventory,
      target: normalized,
      tapPosition: tapPosition,
      route: route,
      surface: surface,
      withBoundsEvidence: withBoundsEvidence,
      legacy: withBoundsEvidence
          ? _legacyAliasContextFor(tokenMap, rootRender, route)
          : null,
      tokenMap: tokenMap,
      rootRender: rootRender,
    );
    final reanchored = !identical(hit.target, normalized);
    // Inventory entries are hashed under the current route's key.
    final keyRoute = reanchored ? route : hit.route;
    final source = identical(hit.target, snapped)
        ? hit.source
        : TugboatTargetResolutionSource.snap;
    final hasFingerprint = normalized?.fingerprint?.isNotEmpty ?? false;
    return (
      inventory: inventory,
      target: normalized,
      source: hasFingerprint ? source : null,
      routeKey: hasFingerprint ? _resolveRouteKey(keyRoute, tokenMap) : null,
    );
  }

  static const _emptyTapContext = (
    inventory: null,
    target: null,
    targetSource: null,
    targetRouteKey: null,
    tapHitsDismissibleBarrier: false,
  );

  /// The tap's hit-test target: fresh at pointer-up, or the kept pressed path
  /// when it is the better evidence. [route] in the result is the route the
  /// winning target was hashed under. `pressedInsideScrollable` says the
  /// pressed control won over a fresh scrollable it sits in.
  ({
    TugboatTargetAnchor? target,
    TugboatTargetResolutionSource source,
    String? route,
    bool pressedInsideScrollable,
  })
  _hitTapTarget(
    Offset tapPosition, {
    required String? route,
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required List<HitTestTarget>? pressedHitPath,
    required String? pressedRoute,
    required bool routeChangedSincePress,
  }) {
    final fresh = _targetAtWithTokenMap(
      tapPosition,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
    );
    final consultPressed =
        pressedHitPath != null &&
        (routeChangedSincePress ||
            !_isActionableWithPath(fresh) ||
            fresh?.role == _scrollableRole);
    if (!consultPressed) {
      return (
        target: fresh,
        source: TugboatTargetResolutionSource.pointerUp,
        route: route,
        pressedInsideScrollable: false,
      );
    }
    return _pressedOrFreshTarget(
      fresh,
      _targetFromHitPath(
        pressedHitPath,
        route: pressedRoute ?? route,
        tokenMap: tokenMap,
        rootRender: rootRender,
        chromeNamesItsControl: true,
      ),
      route: route,
      pressedRoute: pressedRoute ?? route,
      routeChangedSincePress: routeChangedSincePress,
    );
  }

  /// Chooses between the fresh pointer-up target and the [pressed] one. When
  /// the route did not change and [fresh] is actionable, it is a scrollable
  /// and only a control inside it replaces it.
  ({
    TugboatTargetAnchor? target,
    TugboatTargetResolutionSource source,
    String? route,
    bool pressedInsideScrollable,
  })
  _pressedOrFreshTarget(
    TugboatTargetAnchor? fresh,
    TugboatTargetAnchor? pressed, {
    required String? route,
    required String? pressedRoute,
    required bool routeChangedSincePress,
  }) {
    final byScrollable =
        !routeChangedSincePress && _isActionableWithPath(fresh);
    final chosen = byScrollable
        ? _preferPressedInside(fresh, pressed)
        : _preferPressedIfUsable(fresh, pressed);
    final usedPressed = pressed != null && identical(chosen, pressed);
    return (
      target: chosen,
      source: usedPressed
          ? TugboatTargetResolutionSource.pointerDown
          : TugboatTargetResolutionSource.pointerUp,
      route: usedPressed ? pressedRoute : route,
      pressedInsideScrollable: byScrollable && usedPressed,
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
    bool nameHiddenControls = true,
  }) {
    final result = BoxHitTestResult();
    final localPosition = rootRender.globalToLocal(globalPosition);
    rootRender.hitTest(result, position: localPosition);
    return _targetFromHitPath(
      _hitTargets(result),
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
      nameHiddenControls: nameHiddenControls,
    );
  }

  static bool _hasPath(TugboatTargetAnchor? anchor) =>
      anchor?.canonicalPath?.isNotEmpty ?? false;

  /// The pressed target replaces [fresh] when it is actionable, or when it at
  /// least has a path and [fresh] has none. A control built under
  /// `ExcludeSemantics` has no role in the token map, but its path still
  /// identifies it; an empty anchor identifies nothing.
  static TugboatTargetAnchor? _preferPressedIfUsable(
    TugboatTargetAnchor? fresh,
    TugboatTargetAnchor? pressed,
  ) {
    if (_isActionableWithPath(pressed)) return pressed;
    if (!_hasPath(fresh) && _hasPath(pressed)) return pressed;
    return fresh;
  }

  static const _scrollableRole = 'scrollable';

  /// [fresh] is a scrollable. The pressed target replaces it only when it is
  /// a control inside that scrollable: the tap's own `onTap` started an
  /// animated scroll (`PageController.nextPage`), which makes the scrollable
  /// ignore pointers at once, so the pointer-up hit test stops at the
  /// scrollable. A tap on the scrollable itself keeps it.
  static TugboatTargetAnchor? _preferPressedInside(
    TugboatTargetAnchor? fresh,
    TugboatTargetAnchor? pressed,
  ) {
    final outer = fresh?.canonicalPath;
    final inner = pressed?.canonicalPath;
    if (outer == null || inner == null || !_isActionableWithPath(pressed)) {
      return fresh;
    }
    return inner.startsWith('$outer/') ? pressed : fresh;
  }

  static bool _isActionableWithPath(TugboatTargetAnchor? anchor) =>
      anchor != null &&
      anchor.role != null &&
      (anchor.canonicalPath?.isNotEmpty ?? false);

  TugboatTargetAnchor? _targetFromHitPath(
    List<HitTestTarget> hitPath, {
    required String? route,
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    bool nameHiddenControls = true,
    bool chromeNamesItsControl = false,
  }) => _resolveHitPath(
    hitPath,
    route: route,
    tokenMap: tokenMap,
    rootRender: rootRender,
    nameHiddenControls: nameHiddenControls,
    chromeNamesItsControl: chromeNamesItsControl,
  ).anchor;

  /// The anchor for [hitPath] and, when a control hidden under
  /// `ExcludeSemantics` names it, that control. [nameHiddenControls] false
  /// resolves as before that rule: the inventory's centre hits for an
  /// enclosing scrollable must not adopt the hidden control (its entry is
  /// added with its own box, see [_addExcludedSemanticsControls]).
  ///
  /// [chromeNamesItsControl] is set for the hit path kept at pointer-down
  /// (BLE-440). A tap on a button's padding hits the button's own gesture
  /// `Listener` first. Skipping it as chrome starts the climb above the
  /// `GestureDetector` (at `MouseRegion`), so the target lands on the
  /// `InkWell`. On the fresh pointer-up path, alias normalisation folds that
  /// back to the inventory primary, but after a navigating tap it cannot run.
  /// With the flag, a chrome entry whose own climb reaches an actionable,
  /// addressable control resolves to that control: the layer a glyph tap
  /// and the scene inventory report. It does not apply when a control
  /// hidden under `ExcludeSemantics` names the hit.
  ({TugboatTargetAnchor? anchor, Element? hiddenControl}) _resolveHitPath(
    List<HitTestTarget> hitPath, {
    required String? route,
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    bool nameHiddenControls = true,
    bool chromeNamesItsControl = false,
  }) {
    final viewport = rootRender.size;
    final fallbacks = _HitFallbacks();
    // Only the first retained element above the excluded subtree can be
    // named by the control hidden in it.
    var hidden = _hiddenControlIf(nameHiddenControls, hitPath, tokenMap);
    // A control hidden under `ExcludeSemantics` has no role of its own, so a
    // climb from chrome inside it would pass it by; its own rule names it.
    final chromeAllowed = chromeNamesItsControl && hidden == null;
    for (final target in hitPath) {
      final chromeControl = _chromeHitControl(
        chromeAllowed,
        target,
        route,
        tokenMap,
        rootRender,
      );
      if (chromeControl != null) {
        return (anchor: chromeControl, hiddenControl: null);
      }
      final element = _retainedHitElement(target, tokenMap);
      if (element == null) continue;

      final named = _hiddenControlNaming(hidden, element, tokenMap);
      hidden = null;
      final anchor = _anchorForElement(
        hitElement: element,
        rootRender: rootRender,
        viewport: viewport,
        route: route,
        tokenMap: tokenMap,
        hiddenControl: named,
      );
      if (named != null) return (anchor: anchor, hiddenControl: named);
      // Prefer an anchor that is both actionable and structurally addressable.
      // A role without a canonical path (e.g. a Texture overlay with a
      // long-press ancestor) cannot join a scene inventory, so keep scanning
      // for a deeper hit entry that can.
      if (_isActionableWithPath(anchor)) {
        return (anchor: anchor, hiddenControl: null);
      }
      fallbacks.note(anchor);
    }
    return (anchor: fallbacks.best, hiddenControl: null);
  }

  _HiddenControl? _hiddenControlIf(
    bool enabled,
    List<HitTestTarget> hitPath,
    _TokenMap tokenMap,
  ) => enabled ? _hiddenControlOnHitPath(hitPath, tokenMap) : null;

  /// The retained element of one hit-path entry, or null when the entry is
  /// detached, not retained, or capture chrome.
  Element? _retainedHitElement(HitTestTarget target, _TokenMap tokenMap) {
    if (target is! RenderObject || !target.attached) return null;
    final element = tokenMap.renderElements[target];
    if (element == null || _isSkippedChrome(element, tokenMap)) return null;
    return element;
  }

  /// The control a capture-chrome hit entry belongs to, when [allowed] and
  /// climbing from it reaches one that is actionable and has a path. Null
  /// for anything else, so the entry is skipped exactly as before.
  TugboatTargetAnchor? _chromeHitControl(
    bool allowed,
    HitTestTarget target,
    String? route,
    _TokenMap tokenMap,
    RenderBox rootRender,
  ) {
    if (!allowed || target is! RenderObject || !target.attached) return null;
    final element = tokenMap.renderElements[target];
    if (element == null || !_isSkippedChrome(element, tokenMap)) return null;
    final anchor = _anchorForElement(
      hitElement: element,
      rootRender: rootRender,
      viewport: rootRender.size,
      route: route,
      tokenMap: tokenMap,
    );
    return _isActionableWithPath(anchor) ? anchor : null;
  }

  /// A low-level identity (a Listener, a tap Semantics) names itself rather
  /// than the first non-chrome widget under the hit. Null otherwise.
  String? _lowLevelIdentityName(Element? identity, _TokenMap tokenMap) {
    if (identity == null) return null;
    return tokenMap.newRoleCandidates.contains(identity)
        ? _widgetName(identity.widget)
        : null;
  }

  /// Capture chrome is skipped unless it is a low-level control of its own (a
  /// pointer-up Listener or a tap Semantics).
  bool _isSkippedChrome(Element element, _TokenMap tokenMap) =>
      tugboatIsCaptureChrome(element.widget) &&
      !tokenMap.newRoleCandidates.contains(element);

  /// [hiddenControl] is a control hidden under `ExcludeSemantics` that names
  /// this hit ([_hiddenControlNaming]): it supplies the role, actions, widget
  /// type and box, and the hit keeps [hitElement]'s path, the identity a tap
  /// on such a control has always had when nothing encloses it.
  TugboatTargetAnchor _anchorForElement({
    required Element hitElement,
    required RenderBox rootRender,
    required Size viewport,
    required String? route,
    required _TokenMap tokenMap,
    Element? hiddenControl,
  }) {
    final described = _describeHit(hiddenControl ?? hitElement, tokenMap);
    final identity = _hitIdentity(hitElement, hiddenControl, tokenMap);
    final identityElement = identity.element;
    final widgetType =
        _lowLevelIdentityName(identityElement, tokenMap) ??
        described.widgetType;
    final bounds = _rawBoundsForElement(identity.box, rootRender);
    final fpElement = identity.path;
    final routeKey = _resolveRouteKey(route, tokenMap);
    final tagId = _tagIdForElement(fpElement, tokenMap);
    // The path already carries hashed discriminators (e.g. `[item:a1b2]`), so
    // it is the sole structural determinant of identity.
    final path = _pathFor(fpElement, tokenMap);

    // Hash input includes the full structural path. It is the determinant of
    // identity but far too verbose to ship on every event, so it stays here.
    final fingerprint = _fingerprintForParts({
      'routeKey': routeKey,
      'path': path,
    });

    return TugboatTargetAnchor(
      schemaVersion: tugboatFingerprintSchemaVersion,
      widgetType: widgetType,
      role: described.role,
      fingerprint: fingerprint.isEmpty ? null : fingerprint,
      fingerprintConfidence: fingerprint.isEmpty
          ? null
          : _anchorConfidence(routeKey, fpElement, tokenMap),
      tagFingerprint: tagId == null
          ? null
          : _fingerprintForParts({'routeKey': routeKey, 'tag': tagId}),
      // Serialized evidence: only the small, human-meaningful fields. The
      // full path lives in [fingerprint], not on the wire.
      fingerprintParts: {
        'schemaVersion': tugboatFingerprintSchemaVersion.toString(),
        'routeKey': routeKey,
        if (tagId != null) 'tag': tagId,
      },
      canonicalPath: path,
      relativePosition: _relativePosition(bounds, viewport),
      enabled: described.enabled,
      actions: described.actions,
    );
  }

  /// The identity element of a hit (none for a hidden control, which keeps
  /// [hitElement]'s path), the element whose path is hashed, and the element
  /// whose box the anchor reports.
  ({Element? element, Element path, Element box}) _hitIdentity(
    Element hitElement,
    Element? hiddenControl,
    _TokenMap tokenMap,
  ) {
    if (hiddenControl != null) {
      return (element: null, path: hitElement, box: hiddenControl);
    }
    final identity = _identityElementFor(hitElement, tokenMap);
    return (
      element: identity,
      path: identity ?? hitElement,
      box: identity ?? hitElement,
    );
  }

  /// A structural list position keeps sibling controls distinct without
  /// making visible copy or icon data part of their identity.
  String _anchorConfidence(
    String routeKey,
    Element fpElement,
    _TokenMap tokenMap,
  ) {
    final hasItemPosition = _hasInheritedItemPosition(fpElement, tokenMap);
    return _confidenceFloor([
      _routeKeyConfidence(routeKey),
      hasItemPosition ? 'medium' : 'low',
    ]);
  }

  /// Role, enabled state and actions of the first role at or above
  /// [inspected]; a text field's inner `Scrollable` yields to the text field.
  /// Actions are that role's own, as on native Android (empty when disabled);
  /// a parent's role, such as a scrollable list, adds none. The widget type is
  /// the nearest widget to the hit that is not capture chrome (a leaf such as
  /// `RichText` for a labelled button); it is unchanged by this fix.
  ({String? role, bool? enabled, List<String> actions, String? widgetType})
  _describeHit(Element inspected, _TokenMap tokenMap) {
    final roles = <WidgetRole>[];
    String? widgetType;
    // The first role is plumbing (the tap detector or ink inside a switch,
    // checkbox or radio, or the tile row of a *ListTile); the toggle that
    // owns it is the first toggle role at or above the hit.
    var firstIsPlumbing = false;
    WidgetRole? toggle;

    void inspectElement(Element element) {
      final widget = element.widget;
      final widgetRole = _anchorRoleFor(element, tokenMap);
      if (widgetRole != null && roles.isEmpty) {
        firstIsPlumbing = _isTogglePlumbing(widget);
      }
      if (widgetRole != null && _toggleRoles.contains(widgetRole.name)) {
        toggle ??= widgetRole;
      }
      if (widgetRole != null && roles.length < 2) roles.add(widgetRole);
      if (tugboatRoleForWidget(widget) != null) {
        widgetType ??= _widgetName(widget);
      } else if (widgetType == null && !tugboatIsCaptureChrome(widget)) {
        widgetType = _widgetName(widget);
      }
    }

    inspectElement(inspected);
    inspected.visitAncestorElements((ancestor) {
      inspectElement(ancestor);
      return true;
    });
    // A text field's inner Scrollable sits below the TextField itself, so
    // the text field describes the hit (native ranks textField first too).
    final described =
        roles.length == 2 &&
            roles[0].name == 'scrollable' &&
            roles[1].name == 'textField'
        ? roles[1]
        : firstIsPlumbing && toggle != null
        ? toggle
        : roles.firstOrNull;
    return (
      role: described?.name,
      enabled: described?.enabled,
      actions: [...?described?.actions]..sort(),
      widgetType: widgetType,
    );
  }

  static const _toggleRoles = {'switch', 'checkbox', 'radio'};

  /// Widgets a toggle control builds from, which carry a `button` role of
  /// their own. A button a host app puts inside a toggle's row is not one.
  bool _isTogglePlumbing(Widget widget) =>
      widget is GestureDetector ||
      widget is InkWell ||
      widget is InkResponse ||
      widget is ListTile;

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

  _TokenMap _buildTokenMap(
    Element rootElement,
    RenderBox rootRender, {
    bool legacy = false,
  }) {
    if (!legacy) debugTokenMapBuildCount++;
    final controlCandidates = <Element>{};
    final newRoleCandidates = <Element>{};
    final tokens = <Element, String>{};
    final retainedParents = <Element, Element?>{};
    final tagIds = <Element, String>{};
    final isActionable = <Element, bool>{};
    final hasActionableDescendant = <Element, bool>{};
    final hasTokenizedActionableDescendant = <Element, bool>{};
    final isSensitiveMap = <Element, bool>{};
    final ordinalCounters = <Object, int>{};
    final renderElements = <RenderObject, Element>{};
    final includedElements = <Element>{};
    final visitor = _TokenMapVisitor(
      this,
      rootRender,
      legacy: legacy,
      controlCandidates: controlCandidates,
      newRoleCandidates: newRoleCandidates,
      tokens: tokens,
      retainedParents: retainedParents,
      tagIds: tagIds,
      isActionable: isActionable,
      hasActionableDescendant: hasActionableDescendant,
      hasTokenizedActionableDescendant: hasTokenizedActionableDescendant,
      isSensitive: isSensitiveMap,
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
      final role = _leafActionableRole(
        element,
        isActionable,
        hasActionableDescendant,
        tokens,
      );
      if (role == null) continue;
      actionableSummary[role.name] = (actionableSummary[role.name] ?? 0) + 1;
      if (legacy) {
        actionablePaths.add(_pathForMaps(element, tokens, retainedParents));
      }
    }
    final candidates = {...controlCandidates, ...newRoleCandidates};
    final identityAncestors = _retainedAncestorsOf(
      legacy ? const <Element>[] : candidates.where(tokens.containsKey),
      retainedParents,
    );
    actionablePaths.addAll(
      _identityLeafPaths(
        tokens: tokens,
        retainedParents: retainedParents,
        candidates: legacy ? const <Element>{} : candidates,
        ancestors: identityAncestors,
      ),
    );

    final sortedPaths =
        actionablePaths.map(_normalizeItemPathForSignature).toSet().toList()
          ..sort();
    final structuralRouteSignature = tugboatLabelHash(sortedPaths.join('|'));

    return _TokenMap(
      root: rootElement,
      rootRender: rootRender,
      legacy: legacy,
      controlCandidates: controlCandidates,
      newRoleCandidates: newRoleCandidates,
      identityAncestors: identityAncestors,
      tokens: tokens,
      retainedParents: retainedParents,
      tagIds: tagIds,
      isActionable: isActionable,
      hasActionableDescendant: hasActionableDescendant,
      hasTokenizedActionableDescendant: hasTokenizedActionableDescendant,
      isSensitive: isSensitiveMap,
      structuralRouteSignature: structuralRouteSignature,
      renderElements: renderElements,
      hasBlockingOverlay: visitor.rootHasBlockingOverlay,
      hasDismissibleModalBarrier: visitor.hasDismissibleModalBarrier,
      excludedSemantics: visitor.excludedSemantics,
      includedElements: includedElements,
      actionableSummary: actionableSummary,
      subLabel: visitor.subLabel,
    );
  }

  /// The enabled schema 6 role of a tokenized actionable leaf, else null.
  WidgetRole? _leafActionableRole(
    Element element,
    Map<Element, bool> isActionable,
    Map<Element, bool> hasActionableDescendant,
    Map<Element, String> tokens,
  ) {
    if (isActionable[element] != true || !tokens.containsKey(element)) {
      return null;
    }
    if (hasActionableDescendant[element] == true) return null;
    final role = tugboatRoleForWidget(element.widget);
    return role == null || role.enabled == false ? null : role;
  }

  /// Retained ancestors of [candidates].
  Set<Element> _retainedAncestorsOf(
    Iterable<Element> candidates,
    Map<Element, Element?> retainedParents,
  ) {
    final ancestors = <Element>{};
    for (final element in candidates) {
      var parent = retainedParents[element];
      while (parent != null && ancestors.add(parent)) {
        parent = retainedParents[parent];
      }
    }
    return ancestors;
  }

  /// Paths of the control identities that carry no other identity below them.
  ///
  /// Disabled controls and their stand-ins are candidates too, so enabled and
  /// disabled twins name the same leaves.
  Set<String> _identityLeafPaths({
    required Map<Element, String> tokens,
    required Map<Element, Element?> retainedParents,
    required Set<Element> candidates,
    required Set<Element> ancestors,
  }) => {
    for (final element in candidates)
      if (tokens.containsKey(element) && !ancestors.contains(element))
        _pathForMaps(element, tokens, retainedParents, canonical: true),
  };

  /// Schema 6 roles stay one kind of identity. Schema 7 adds the low-level
  /// roles and the gesture stand-ins of disabled controls.
  _IdentityKind _identityKindOf(Element element, {required bool legacy}) {
    final widget = element.widget;
    final schema6 = tugboatRoleForWidget(widget);
    if (schema6 != null) {
      return legacy || !_isBareDisabledInk(widget, schema6)
          ? _IdentityKind.control
          : _IdentityKind.none;
    }
    if (legacy) return _IdentityKind.none;
    if (_standInRoleOf(element) != null) return _IdentityKind.control;
    return _roleOf(element, legacy: false) != null
        ? _IdentityKind.lowLevel
        : _IdentityKind.none;
  }

  /// An ink area without `onTap` is plumbing (a ListTile's ripple, a passive
  /// InkWell), not a disabled control. Its enabled twin is an InkWell too, so
  /// a disabled control's own role still names it.
  bool _isBareDisabledInk(Widget widget, WidgetRole role) =>
      role.enabled == false && (widget is InkWell || widget is InkResponse);

  /// The role of the disabled control that a [GestureDetector] without a tap
  /// callback stands in for: the nearest enclosing control, when it is
  /// disabled. The enabled twin's tap detector is this same element, so the
  /// disabled control keeps its identity. Inside an enabled control such a
  /// detector is not an identity, as in schema 6. Null otherwise.
  WidgetRole? _standInRoleOf(Element element) {
    if (element.widget is! GestureDetector) return null;
    WidgetRole? enclosing;
    element.visitAncestorElements((ancestor) {
      enclosing = _enclosingControlRole(ancestor.widget);
      return enclosing == null;
    });
    return enclosing?.enabled == false ? enclosing : null;
  }

  /// The schema 6 role of a control that owns the gesture plumbing below it:
  /// not a scrollable and not a bare ink area.
  WidgetRole? _enclosingControlRole(Widget widget) {
    final role = tugboatRoleForWidget(widget);
    if (role == null || role.name == 'scrollable') return null;
    return _isBareDisabledInk(widget, role) ? null : role;
  }

  /// A low-level role is a control of its own only outside every control and
  /// around no schema 6 role. One inside a control is that control's plumbing,
  /// and one around a control (a pointer-up `Listener` around a button) is a
  /// layer of it. Either way it keeps no path segment, so no schema 6 path of
  /// a control moves.
  bool _isOwnLowLevelControl(Element element) =>
      !_hasControlAncestor(element) && !_hasRoleBelow(element);

  bool _hasControlAncestor(Element element) {
    var found = false;
    element.visitAncestorElements((ancestor) {
      found = _enclosingControlRole(ancestor.widget) != null;
      return !found;
    });
    return found;
  }

  bool _hasRoleBelow(Element element) {
    var found = false;
    void visit(Element child) {
      if (found) return;
      found = tugboatRoleForWidget(child.widget) != null;
      if (!found) child.visitChildElements(visit);
    }

    element.visitChildElements(visit);
    return found;
  }

  /// The role of [element] for identity and inventory. The schema 6 walk uses
  /// the schema 6 role set only. Navigator's own pointer listener is not an app
  /// control, whatever its handler does.
  WidgetRole? _roleOf(Element element, {required bool legacy}) {
    final widget = element.widget;
    if (legacy || _isFrameworkLowLevel(element)) {
      return tugboatRoleForWidget(widget);
    }
    return tugboatInteractiveRoleForWidget(widget);
  }

  /// Low-level roles the framework builds for itself and no app widget owns:
  /// the Navigator's pointer listener, and the dismiss `Semantics` of a modal
  /// barrier. They are not controls of the app.
  bool _isFrameworkLowLevel(Element element) {
    final widget = element.widget;
    if (widget is Listener) return _isNavigatorOwned(element);
    if (widget is Semantics) {
      return element.findAncestorWidgetOfExactType<ModalBarrier>() != null;
    }
    return false;
  }

  bool _isNavigatorOwned(Element element) {
    var owned = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor is StatefulElement) {
        owned = ancestor.state is NavigatorState;
        return false;
      }
      return true;
    });
    return owned;
  }

  /// The identity element of a hit: the innermost control (any enabled state,
  /// scrollables included, as in schema 6) or low-level control of its own.
  /// A disabled control whose subtree ignores the hit is then mapped onto its
  /// enabled twin's identity ([_disabledTwinIdentity]).
  Element? _identityElementFor(Element hit, _TokenMap map) {
    Element? found;
    bool consider(Element element) {
      if (_isIdentityAt(element, map)) found = element;
      return found == null;
    }

    if (consider(hit)) hit.visitAncestorElements(consider);
    final identity = found;
    if (identity == null || map.legacy) return identity;
    return _disabledTwinIdentity(identity, map) ?? identity;
  }

  bool _isIdentityAt(Element element, _TokenMap map) =>
      map.newRoleCandidates.contains(element) ||
      _identityKindOf(element, legacy: map.legacy) == _IdentityKind.control;

  /// The identity of a disabled control the hit could not reach into (a
  /// disabled `TextField` ignores pointers): the innermost control below it,
  /// when the controls below form one chain of disabled controls, stand-ins
  /// and scrollables. That is where its enabled twin's hit lands, so toggling
  /// `enabled` keeps the fingerprint. Null when it does not apply.
  Element? _disabledTwinIdentity(Element identity, _TokenMap map) {
    if (tugboatRoleForWidget(identity.widget)?.enabled != false) return null;
    Element? deepest;
    for (final candidate in map.controlCandidates) {
      if (!_isRetainedBelow(candidate, identity, map)) continue;
      if (!_isPassiveTwinPart(candidate)) return null;
      if (deepest == null || _isRetainedBelow(candidate, deepest, map)) {
        deepest = candidate;
      } else if (!_isRetainedBelow(deepest, candidate, map)) {
        return null;
      }
    }
    return deepest;
  }

  /// A disabled control, a stand-in or a scrollable: never an enabled control.
  bool _isPassiveTwinPart(Element element) =>
      tugboatRoleForWidget(element.widget)?.enabled != true;

  /// Whether tokenized [element] has [ancestor] on its retained parent chain.
  bool _isRetainedBelow(Element element, Element ancestor, _TokenMap map) {
    if (!map.tokens.containsKey(element)) return false;
    var parent = map.retainedParents[element];
    while (parent != null) {
      if (identical(parent, ancestor)) return true;
      parent = map.retainedParents[parent];
    }
    return false;
  }

  /// The role an anchor reports for [element]: its schema 6 role, or its
  /// low-level role when it is a control of its own. A plumbing role inside a
  /// control, or an SDK or framework listener, never names or enables a hit.
  WidgetRole? _anchorRoleFor(Element element, _TokenMap map) =>
      tugboatRoleForWidget(element.widget) ??
      (map.newRoleCandidates.contains(element)
          ? tugboatInteractiveRoleForWidget(element.widget)
          : null);

  /// The role an inventory entry reports for [element]: its own, or for a
  /// stand-in the role of the disabled control it stands in for.
  WidgetRole? _inventoryRoleOf(Element element, _TokenMap map) =>
      _roleOf(element, legacy: map.legacy) ??
      (map.legacy ? null : _standInRoleOf(element));

  /// The schema 6 walk of [map]'s tree, built once per token map for aliases.
  _TokenMap _legacyMapFor(_TokenMap map) =>
      map.legacyMap ??= _buildTokenMap(map.root, map.rootRender, legacy: true);

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

  String _pathFor(Element element, _TokenMap tokenMap) => _pathForMaps(
    element,
    tokenMap.tokens,
    tokenMap.retainedParents,
    canonical: !tokenMap.legacy,
  );

  /// Whether [element] or a retained ancestor has a structural item position.
  bool _hasInheritedItemPosition(Element element, _TokenMap tokenMap) {
    Element? current = element;
    while (current != null) {
      if (tokenMap.tokens[current]?.startsWith('[item:') == true) return true;
      current = tokenMap.retainedParents[current];
    }
    return false;
  }

  /// The canonical path of [element]. [canonical] drops the ordinal of an
  /// overlay host (schema 7); schema 6 paths keep it.
  String _pathForMaps(
    Element element,
    Map<Element, String> tokens,
    Map<Element, Element?> retainedParents, {
    bool canonical = false,
  }) {
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
      if (token != null) parts.add(canonical ? _canonicalToken(token) : token);
      current = retainedParents[current];
    }
    return parts.reversed.join('/');
  }

  /// `DisplayFeatureSubScreen#2` -> `DisplayFeatureSubScreen` for an overlay
  /// host; any other token is unchanged.
  String _canonicalToken(String token) {
    final type = _tokenTypeName(token);
    return type != null && _overlayHostWidgets.contains(type) ? type : token;
  }

  static bool _isCaptureRoot(Widget widget) {
    final key = widget.key;
    return key is ValueKey<String> &&
        key.value.startsWith(tugboatCaptureRootKeyPrefix);
  }

  String? _tagIdFromWidget(Widget widget) {
    if (widget is TugboatTag) return widget.id;
    // The SDK's own capture root is keyed too; it is not a developer alias.
    if (_isCaptureRoot(widget)) return null;
    final key = widget.key;
    if (key is ValueKey<String>) return key.value;
    return null;
  }

  String? _tagIdForElement(Element element, _TokenMap tokenMap) {
    var current = element;
    while (true) {
      // The capture root is the SDK's own widget: nothing at or above it is
      // a tag for a control inside the capture.
      if (_isCaptureRoot(current.widget)) break;
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
    final surfaceKey = _surfaceRouteKey(route, tokenMap);
    if (surfaceKey != null) return surfaceKey;
    if (route != null && route.isNotEmpty && !_isAnonymousRouteName(route)) {
      return route;
    }
    return 'struct:${tokenMap.structuralRouteSignature}';
  }

  /// `sheet:<WidgetClass>` or `dialog:<WidgetClass>` for an anonymous sheet or
  /// dialog route (schema 7, #137), when its widget class is known. The route
  /// string names the kind: an anonymous route's string is its runtime type
  /// (`ModalBottomSheetRoute<bool>`). A host-named route keeps its name, and
  /// a popup cannot be told from its type name, so it keeps its key too.
  String? _surfaceRouteKey(String? route, _TokenMap tokenMap) {
    if (tokenMap.legacy || route == null || route.isEmpty) return null;
    final kind = _sheetOrDialogKindOf(route);
    if (kind == null) return null;
    final widgetClass = _surfaceClassFor(tokenMap, kind);
    return widgetClass == null ? null : '$kind:$widgetClass';
  }

  /// `sheet` or `dialog` for the runtime type names of anonymous sheet and
  /// dialog routes (the same names as `tugboatSurfaceKindForRouteType`).
  String? _sheetOrDialogKindOf(String route) {
    final generic = route.indexOf('<');
    final base = generic == -1 ? route : route.substring(0, generic);
    const sheets = {
      'ModalBottomSheetRoute',
      'CupertinoModalPopupRoute',
      'CupertinoSheetRoute',
    };
    const dialogs = {'DialogRoute', 'RawDialogRoute', 'CupertinoDialogRoute'};
    final name = base.startsWith('_') ? base.substring(1) : base;
    if (sheets.contains(name)) return TugboatSurfaceKind.sheet;
    if (dialogs.contains(name)) return TugboatSurfaceKind.dialog;
    return null;
  }

  /// The widget class of the tree's sheet or dialog, cached per token map.
  String? _surfaceClassFor(_TokenMap tokenMap, String kind) {
    if (!tokenMap.surfaceClassKnown) {
      tokenMap
        ..surfaceClass = _surfaceFor(tokenMap, kind: kind).widgetClass
        ..surfaceClassKnown = true;
    }
    return tokenMap.surfaceClass;
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

  String? _normalizedWidgetTypeName(Widget widget, {bool allowChrome = false}) {
    if (!allowChrome && tugboatIsCaptureChrome(widget)) return null;
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

  /// The retained type of a widget that is not an actionable role. Schema 7
  /// also drops the component theme wrappers ([_canonicalWrapperDenylist]).
  String? _canonicalType(Widget widget, {required bool legacy}) {
    final type = _normalizedWidgetTypeName(widget);
    if (type == null || _canonicalDenylist.contains(type)) return null;
    if (!legacy && _canonicalWrapperDenylist.contains(type)) return null;
    return type;
  }

  /// Type name for an actionable widget that must be retained even when it is
  /// on the wrapper denylist (e.g. InkWell).
  String? _actionableTypeName(Widget widget) =>
      _normalizedWidgetTypeName(widget, allowChrome: true);

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
    final rect = _paintRectInRoot(element, rootRender);
    return rect == null
        ? null
        : TugboatNormalizedBounds.fromRect(rect, viewport);
  }

  /// The element's paint bounds (not its hit-test box), unclipped, in the
  /// capture boundary's coordinates. Null when it has no laid-out box.
  Rect? _paintRectInRoot(Element element, RenderBox rootRender) {
    final render = element.renderObject;
    if (render is! RenderBox || !render.hasSize) return null;
    try {
      return MatrixUtils.transformRect(
        render.getTransformTo(rootRender),
        render.paintBounds,
      );
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

/// The first role-only and the first role-less anchor along a hit path, kept
/// while the walk looks for one that is both actionable and addressable.
class _HitFallbacks {
  TugboatTargetAnchor? _roleOnly;
  TugboatTargetAnchor? _fallback;

  void note(TugboatTargetAnchor anchor) {
    if (anchor.role != null) {
      _roleOnly ??= anchor;
    } else {
      _fallback ??= anchor;
    }
  }

  TugboatTargetAnchor? get best => _roleOnly ?? _fallback;
}
