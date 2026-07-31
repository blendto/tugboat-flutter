part of 'anchors.dart';

class _TokenMap {
  _TokenMap({
    required this.tokens,
    required this.retainedParents,
    required this.tagIds,
    required this.labelAnnotations,
    required this.hasBareItem,
    required this.isActionable,
    required this.hasActionableDescendant,
    required this.hasTokenizedActionableDescendant,
    required this.isSensitive,
    required this.underActionable,
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
  final Map<Element, bool> hasActionableDescendant;
  final Map<Element, bool> hasTokenizedActionableDescendant;
  final Map<Element, bool> isSensitive;
  final Map<Element, bool> underActionable;
  final String structuralRouteSignature;
  final Map<RenderObject, Element> renderElements;
  final bool hasBlockingOverlay;
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

/// Metadata sampled from one interaction target.
///
/// The resolver retains the concrete hit element privately so a post-callback
/// sample can stay bound to the original target instead of re-hit-testing a
/// coordinate that may now belong to another route or overlay.
class TugboatInteractionMetadata {
  const TugboatInteractionMetadata._({
    required Element? element,
    this.controlValue,
    this.semanticAnnotation,
  }) : _element = element;

  final Element? _element;
  final TugboatControlValue? controlValue;
  final TugboatSemanticAnnotation? semanticAnnotation;

  Object? get resampleTargetIdentity => _element;

  TugboatInteractionMetadata detached() => TugboatInteractionMetadata._(
    element: null,
    controlValue: controlValue,
    semanticAnnotation: semanticAnnotation,
  );
}

/// Builds target anchors from hit-test results.
class AnchorResolver {
  AnchorResolver({required this.rootKey, this.widgetNames = const {}});

  final GlobalKey rootKey;
  final Map<Type, String> widgetNames;
  List<int> _controlValueHashKey = _newControlValueHashKey();

  _TokenMap? _cachedTokenMap;
  int? _cachedFrameId;
  RenderBox? _cachedRootRender;
  @visibleForTesting
  int debugTokenMapBuildCount = 0;
  int _frameEpoch = 0;
  bool _frameCallbackScheduled = false;

  void rotateControlValueHashKey() {
    _controlValueHashKey = _newControlValueHashKey();
  }

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
      final widget = element.widget;
      final renderObject = element.renderObject;
      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize) {
        continue;
      }
      final sensitive = tokenMap.isSensitive[element] == true;
      final actionable =
          tokenMap.underActionable[element] == true ||
          tugboatIsActionableWidget(widget);
      if (!shouldMask(element, widget, renderObject, sensitive, actionable)) {
        continue;
      }
      if (!maskedRenderObjects.add(renderObject)) continue;
      try {
        final transformed = MatrixUtils.transformRect(
          renderObject.getTransformTo(rootRender),
          renderObject.paintBounds,
        );
        final rect = transformed.intersect(rootRender.paintBounds);
        if (rect.width > 0 && rect.height > 0) {
          masks.add(rect);
        }
      } catch (_) {
        // Detached render object can race capture; omit its mask safely.
      }
    }
    return masks;
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

  /// Samples control and semantic metadata with one hit test and semantics
  /// session.
  ///
  /// The returned sample can be passed to [resampleInteractionMetadata] after
  /// the host callback runs to read updated state from the same target.
  TugboatInteractionMetadata? interactionMetadataAt(Offset globalPosition) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootRender is! RenderBox || rootContext is! Element) return null;

    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) return null;

    return _withControlValueHashKey(
      _controlValueHashKey,
      () => _withSemanticsEnabled(rootRender, () {
        final result = BoxHitTestResult();
        final localPosition = rootRender.globalToLocal(globalPosition);
        rootRender.hitTest(result, position: localPosition);
        return _interactionMetadataFromHitTest(
          globalPosition: globalPosition,
          result: result,
          tokenMap: tokenMap,
          rootContext: rootContext,
          rootRender: rootRender,
        );
      }),
    );
  }

  TugboatInteractionMetadata _interactionMetadataFromHitTest({
    required Offset globalPosition,
    required BoxHitTestResult result,
    required _TokenMap tokenMap,
    required Element rootContext,
    required RenderBox rootRender,
  }) {
    Element? sampledElement;
    TugboatControlValue? controlValue;
    TugboatSemanticAnnotation? semanticAnnotation;
    for (final entry in result.path) {
      if (entry.target is! RenderObject) continue;
      final element = tokenMap.renderElements[entry.target as RenderObject];
      if (element == null || tugboatIsCaptureChrome(element.widget)) continue;
      final nextControl = controlValue == null
          ? tugboatControlValueForElement(element)
          : null;
      final nextSemantic = semanticAnnotation == null
          ? tugboatSemanticAnnotationForElement(element)
          : null;
      if (nextControl != null || nextSemantic != null) {
        sampledElement ??= element;
        controlValue ??= nextControl;
        semanticAnnotation ??= nextSemantic;
      }
      if (controlValue != null && semanticAnnotation != null) break;
    }

    // An overlay can sit outside this capture boundary while the global
    // semantics tree still contains the actual control at the tap point. Use
    // a complete semantic parameter pair from that tree in preference to
    // metadata from an obscured control underneath the overlay.
    final hits = _semanticsNodesAt(
      globalPosition: globalPosition,
      rootContext: rootContext,
      rootRender: rootRender,
    );
    final semanticFromHits = _semanticAnnotationFromHits(hits);
    final semanticPair =
        semanticFromHits?.label != null && semanticFromHits?.value != null;
    final localSemanticPair =
        semanticAnnotation?.label != null && semanticAnnotation?.value != null;
    if (semanticAnnotation == null || (!localSemanticPair && semanticPair)) {
      semanticAnnotation = semanticFromHits ?? semanticAnnotation;
    }

    final controlFromHits = _controlValueFromSemanticsHits(hits);
    if (controlValue == null ||
        (!localSemanticPair &&
            semanticPair &&
            controlValue.sources.contains('semantics'))) {
      controlValue = controlFromHits ?? controlValue;
    }

    return TugboatInteractionMetadata._(
      element: sampledElement,
      controlValue: controlValue,
      semanticAnnotation: semanticAnnotation,
    );
  }

  /// Re-samples state from the exact element captured by
  /// [interactionMetadataAt].
  TugboatInteractionMetadata? resampleInteractionMetadata(
    TugboatInteractionMetadata sample,
  ) {
    final element = sample._element;
    if (element == null || !element.mounted) return null;
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();

    TugboatInteractionMetadata readElement() => TugboatInteractionMetadata._(
      element: null,
      controlValue: tugboatControlValueForElement(element),
      semanticAnnotation: tugboatSemanticAnnotationForElement(element),
    );

    return _withControlValueHashKey(
      _controlValueHashKey,
      () => rootRender is RenderBox
          ? _withSemanticsEnabled(rootRender, readElement)
          : readElement(),
    );
  }

  /// Semantic annotation for an [element] already in the tree.
  TugboatSemanticAnnotation? semanticAnnotationForElement(Element element) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootRender is! RenderBox) {
      return tugboatSemanticAnnotationForElement(element);
    }
    return _withControlValueHashKey(
      _controlValueHashKey,
      () => _withSemanticsEnabled(
        rootRender,
        () => tugboatSemanticAnnotationForElement(element),
      ),
    );
  }

  T _withSemanticsEnabled<T>(RenderBox rootRender, T Function() body) {
    final pipelineOwner =
        rootRender.owner ?? RendererBinding.instance.rootPipelineOwner;
    final semanticsAlreadyEnabled =
        pipelineOwner.semanticsOwner != null ||
        RendererBinding.instance.rootPipelineOwner.semanticsOwner != null;
    final semanticsHandle = semanticsAlreadyEnabled
        ? null
        : SemanticsBinding.instance.ensureSemantics();
    try {
      if (!semanticsAlreadyEnabled) {
        pipelineOwner.flushSemantics();
      }
      return body();
    } finally {
      semanticsHandle?.dispose();
    }
  }

  TugboatSemanticAnnotation? _semanticAnnotationFromHits(
    List<SemanticsNode> hits,
  ) {
    TugboatSemanticAnnotation? merged;
    // hits are root→leaf; reverse so deeper nodes win, ancestors fill gaps.
    for (final node in hits.reversed) {
      final next = tugboatSemanticAnnotationFromNode(node);
      if (next == null) continue;
      merged = merged == null
          ? next
          : tugboatMergeSemanticAnnotations(merged, next);
    }
    return merged;
  }

  TugboatControlValue? _controlValueFromSemanticsHits(
    List<SemanticsNode> hits,
  ) {
    TugboatControlValue? fallback;
    for (final node in hits.reversed) {
      final value = tugboatControlValueFromSemanticsNode(node);
      if (value == null) continue;
      fallback ??= value;
      final annotation = tugboatSemanticAnnotationFromNode(node);
      if (annotation?.label != null && annotation?.value != null) {
        return value;
      }
    }
    return fallback;
  }

  List<SemanticsNode> _semanticsNodesAt({
    required Offset globalPosition,
    required Element rootContext,
    required RenderBox rootRender,
  }) {
    final pipelineOwner =
        rootRender.owner ?? RendererBinding.instance.rootPipelineOwner;
    final semanticsOwner =
        pipelineOwner.semanticsOwner ??
        RendererBinding.instance.rootPipelineOwner.semanticsOwner;
    if (semanticsOwner == null) return const [];
    pipelineOwner.flushSemantics();
    final rootNode = semanticsOwner.rootSemanticsNode;
    if (rootNode == null) return const [];

    final devicePixelRatio = View.maybeOf(rootContext)?.devicePixelRatio ?? 1.0;
    final physical = globalPosition * devicePixelRatio;
    final hits = <SemanticsNode>[];
    _collectSemanticsHits(rootNode, physical, hits, Matrix4.identity());
    return hits;
  }

  void _collectSemanticsHits(
    SemanticsNode node,
    Offset physicalGlobal,
    List<SemanticsNode> hits,
    Matrix4 transformToRoot,
  ) {
    final transform = node.transform;
    final nextTransform = transform == null
        ? transformToRoot
        : (transformToRoot.clone()..multiply(transform));
    final inverted = Matrix4.tryInvert(nextTransform);
    if (inverted != null) {
      final local = MatrixUtils.transformPoint(inverted, physicalGlobal);
      if (node.rect.contains(local)) {
        hits.add(node);
      }
    }
    node.visitChildren((child) {
      _collectSemanticsHits(child, physicalGlobal, hits, nextTransform);
      return true;
    });
  }

  /// Builds inventory and resolves a tap target from one token-map walk.
  ({
    TugboatSceneInventory? inventory,
    TugboatTargetAnchor? target,
    TugboatInteractionMetadata? metadata,
  })
  buildTapContext({
    required Offset tapPosition,
    required String? route,
    required bool keyboardOpen,
    required bool modalOpen,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootRender is! RenderBox || rootContext is! Element) {
      return (inventory: null, target: null, metadata: null);
    }

    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) {
      return (inventory: null, target: null, metadata: null);
    }
    final hitTest = BoxHitTestResult();
    rootRender.hitTest(
      hitTest,
      position: rootRender.globalToLocal(tapPosition),
    );
    final metadata = _withControlValueHashKey(
      _controlValueHashKey,
      () => _withSemanticsEnabled(
        rootRender,
        () => _interactionMetadataFromHitTest(
          globalPosition: tapPosition,
          result: hitTest,
          tokenMap: tokenMap,
          rootContext: rootContext,
          rootRender: rootRender,
        ),
      ),
    );
    final stateAnchor = _stateAnchorFromTokenMap(
      tokenMap: tokenMap,
      route: route,
      keyboardOpen: keyboardOpen,
      modalOpen: modalOpen,
    );
    if (stateAnchor.signature.isEmpty) {
      return (inventory: null, target: null, metadata: metadata);
    }

    var target = _targetAtWithTokenMap(
      tapPosition,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
      hitTest: hitTest,
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
    return (inventory: inventory, target: target, metadata: metadata);
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
    BoxHitTestResult? hitTest,
  }) {
    final viewport = rootRender.size;
    final result = hitTest ?? BoxHitTestResult();
    if (hitTest == null) {
      final localPosition = rootRender.globalToLocal(globalPosition);
      rootRender.hitTest(result, position: localPosition);
    }

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

    Rect? bounds;
    final render = anchorElement.renderObject;
    if (render is RenderBox && render.attached && render.hasSize) {
      try {
        bounds = MatrixUtils.transformRect(
          render.getTransformTo(rootRender),
          render.paintBounds,
        );
      } catch (_) {
        // A scroll/layout update can detach or invalidate a hit render box
        // between hit testing and anchor construction. Bounds are optional.
      }
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
    debugTokenMapBuildCount++;
    final tokens = <Element, String>{};
    final retainedParents = <Element, Element?>{};
    final tagIds = <Element, String>{};
    final labelAnnotations = <Element, String>{};
    final hasBareItem = <Element, bool>{};
    final isActionable = <Element, bool>{};
    final hasActionableDescendant = <Element, bool>{};
    final hasTokenizedActionableDescendant = <Element, bool>{};
    final isSensitiveMap = <Element, bool>{};
    final underActionableMap = <Element, bool>{};
    final ordinalCounters = <Object, int>{};
    final renderElements = <RenderObject, Element>{};
    final includedElements = <Element>{};
    String? subLabel;
    var rootHasBlockingOverlay = false;

    _VisitAcc visit(
      Element element,
      Element? retainedParent,
      bool inList,
      bool sensitive,
      bool underActionable,
    ) {
      final widget = element.widget;
      final renderObject = element.renderObject;
      if (tugboatHidesSubtree(widget) ||
          widget is TugboatInternal ||
          tugboatHidesRenderObject(renderObject)) {
        return const _VisitAcc();
      }
      if (renderObject is RenderExcludeSemantics && renderObject.excluding) {
        return const _VisitAcc();
      }

      final isSensitive = sensitive || widget is TugboatSensitive;
      isSensitiveMap[element] = isSensitive;
      underActionableMap[element] = underActionable;
      if (renderObject != null) renderElements[renderObject] = element;
      if (widget is TugboatSubView && subLabel == null) {
        subLabel = widget.label;
      }

      final retainable = _isRetainable(element, rootRender);
      final canonical = retainable ? _canonicalType(widget) : null;
      final role = retainable ? tugboatRoleForWidget(widget) : null;
      // Salient-node retention: actionable widgets must appear in the path even
      // when they sit on the wrapper denylist (e.g. InkWell, InkResponse).
      final retainType =
          canonical ??
          (role != null && role.enabled != false
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

      final elementIsActionable =
          role != null && role.enabled != false && tokens.containsKey(element);
      if (elementIsActionable) {
        isActionable[element] = true;
      }
      final childUnderActionable =
          underActionable || tugboatIsActionableWidget(widget);

      // Once we emit an `[item]` token we are inside a single list entry, so
      // descendants resume normal tokenization (and only a *nested* list
      // container re-enters list mode). This prevents `[item]/[item]/...` chains.
      final childInList = token == '[item]'
          ? false
          : (inList || _isListContainer(widget));

      var pendingBlocker =
          renderObject is RenderBlockSemantics && renderObject.blocking;
      var hasBlockingOverlay = false;
      var childHasActionable = false;
      var childHasTokenizedActionable = false;
      final childElements = <Element>{};
      element.visitChildElements((child) {
        final childResult = visit(
          child,
          newRetainedParent ?? retainedParent,
          childInList,
          isSensitive,
          childUnderActionable,
        );
        // Overlay-level BlockSemantics (modal barrier) replaces previously
        // collected sibling routes with the blocking child's subtree. Regular
        // OverlayPortal content (Tooltip) does not set pendingBlocker.
        if (childResult.pendingBlocker && _isOverlayLevel(element)) {
          childElements
            ..clear()
            ..add(element);
          // Drop sibling routes from shared maps so hit-tests cannot rejoin them.
          for (final previous in [...includedElements]) {
            if (!identical(previous, element)) {
              includedElements.remove(previous);
            }
          }
          for (final key in [...tokens.keys]) {
            if (!identical(key, element) &&
                !childResult.elements.contains(key)) {
              tokens.remove(key);
              retainedParents.remove(key);
              tagIds.remove(key);
              labelAnnotations.remove(key);
              hasBareItem.remove(key);
              isActionable.remove(key);
              hasActionableDescendant.remove(key);
              hasTokenizedActionableDescendant.remove(key);
              isSensitiveMap.remove(key);
              underActionableMap.remove(key);
            }
          }
          for (final entry in [...renderElements.entries]) {
            final mapped = entry.value;
            if (!identical(mapped, element) &&
                !childResult.elements.contains(mapped)) {
              renderElements.remove(entry.key);
            }
          }
          pendingBlocker = false;
          hasBlockingOverlay = true;
          rootHasBlockingOverlay = true;
        }
        childElements.addAll(childResult.elements);
        pendingBlocker = pendingBlocker || childResult.pendingBlocker;
        hasBlockingOverlay =
            hasBlockingOverlay || childResult.hasBlockingOverlay;
        childHasActionable =
            childHasActionable || childResult.hasActionableDescendant;
        childHasTokenizedActionable =
            childHasTokenizedActionable ||
            childResult.hasTokenizedActionableDescendant;
      });

      if (hasBlockingOverlay) {
        rootHasBlockingOverlay = true;
      }

      includedElements.add(element);
      includedElements.addAll(childElements);
      final actionableInSubtree =
          childHasActionable ||
          childElements.any((child) => isActionable[child] == true);
      final tokenizedActionableInSubtree =
          childHasTokenizedActionable ||
          childElements.any(
            (child) => isActionable[child] == true && tokens.containsKey(child),
          );
      hasActionableDescendant[element] = actionableInSubtree;
      hasTokenizedActionableDescendant[element] = tokenizedActionableInSubtree;

      return _VisitAcc(
        elements: {element, ...childElements},
        pendingBlocker: pendingBlocker,
        hasBlockingOverlay: hasBlockingOverlay,
        hasActionableDescendant: actionableInSubtree || elementIsActionable,
        hasTokenizedActionableDescendant:
            tokenizedActionableInSubtree || elementIsActionable,
      );
    }

    // Visit the full element tree (not only onstage) so OverlayPortal/Tooltip
    // subtrees stay addressable for hit testing, matching pre-merge inclusion.
    rootElement.visitChildElements(
      (child) => visit(child, null, false, false, false),
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
      labelAnnotations: labelAnnotations,
      hasBareItem: hasBareItem,
      isActionable: isActionable,
      hasActionableDescendant: hasActionableDescendant,
      hasTokenizedActionableDescendant: hasTokenizedActionableDescendant,
      isSensitive: isSensitiveMap,
      underActionable: underActionableMap,
      structuralRouteSignature: structuralRouteSignature,
      renderElements: renderElements,
      hasBlockingOverlay: rootHasBlockingOverlay,
      includedElements: includedElements,
      actionableSummary: actionableSummary,
      subLabel: subLabel,
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
      if (tugboatHidesSubtree(nodeWidget) || nodeWidget is TugboatInternal) {
        return;
      }
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

  TugboatStateAnchor buildStateAnchor({
    required String? route,
    required bool keyboardOpen,
    required bool modalOpen,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootContext is! Element || rootRender is! RenderBox) {
      return TugboatStateAnchor(
        keyboardOpen: keyboardOpen,
        modalOpen: modalOpen,
      );
    }

    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) {
      return TugboatStateAnchor(
        keyboardOpen: keyboardOpen,
        modalOpen: modalOpen,
      );
    }
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
