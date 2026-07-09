part of 'anchors.dart';

extension TugboatSceneInventoryApi on AnchorResolver {
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

    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) return null;
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
    rootRender.hitTest(result, position: rootRender.globalToLocal(tapPosition));
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
    rootRender.hitTest(result, position: rootRender.globalToLocal(tapPosition));
    for (final entry in result.path) {
      if (entry.target is! RenderObject) continue;
      final element = tokenMap.renderElements[entry.target as RenderObject];
      if (element == null || tugboatIsCaptureChrome(element.widget)) continue;
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
    // Hit-test once per distinct center (cached). Wrappers that resolve to the
    // same actionable descendant still run through so their structural
    // fingerprints become aliases for edge taps that land on the wrapper.
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

    // Skip wrappers that already expose a tokenized actionable child, but only
    // after the same-chain path above had a chance to contribute aliases.
    if (tokenMap.hasTokenizedActionableDescendant[element] == true) {
      return null;
    }

    if (structuralFingerprint.isEmpty) return null;

    final role = tugboatRoleForWidget(widget);
    return (
      entry: TugboatSceneInventoryEntry(
        fingerprint: structuralFingerprint,
        canonicalPath: structuralPath,
        widgetType: _widgetName(widget),
        role: role?.name,
        actions: [...(role?.actions ?? const [])]..sort(),
        enabled: role?.enabled,
        boundsNorm: bounds,
        tier: 'interactive',
      ),
      structuralFingerprint: structuralFingerprint,
    );
  }

  bool _pathsOnSameChain(String leftPath, String rightPath) {
    return leftPath.startsWith(rightPath) || rightPath.startsWith(leftPath);
  }

  bool _isLargeTextBounds(TugboatNormalizedBounds? bounds) {
    if (bounds == null) return false;
    return bounds.width * bounds.height >= _largeTextAreaThreshold;
  }
}
