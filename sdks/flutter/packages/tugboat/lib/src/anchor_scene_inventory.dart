part of 'anchors.dart';

extension TugboatSceneInventoryApi on AnchorResolver {
  /// Minimum normalized paint area for tokenized [Text] widgets to qualify as
  /// content-tier inventory entries.
  static const double _largeTextAreaThreshold = 0.02;

  /// Enumerates tokenized actionable elements, [Image] widgets, and large
  /// [Text] blocks on the current screen. Fingerprints match [targetAt] for the
  /// same element.
  ///
  /// [surfaceKind] is the [TugboatSurfaceKind] of the current route; it only
  /// labels the inventory's `surface` and never reaches a hash.
  ///
  /// [withBoundsEvidence] adds the `viewport`, `scroll` and per-element
  /// `visibleFraction` evidence. It costs one extra ancestor walk per element,
  /// so only inventories that will be emitted ask for it. None of it reaches a
  /// hash.
  TugboatSceneInventory? buildSceneInventory({
    required String? route,
    required bool keyboardOpen,
    required bool modalOpen,
    String? surfaceKind,
    bool withBoundsEvidence = false,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootContext is! Element || rootRender is! RenderBox) return null;

    final tokenMap = _tokenMapFor(rootContext, rootRender);
    if (tokenMap == null) return null;

    return _buildSceneInventoryFromTokenMap(
      tokenMap: tokenMap,
      rootRender: rootRender,
      route: route,
      surface: _surfaceFor(tokenMap, kind: surfaceKind),
      withBoundsEvidence: withBoundsEvidence,
    );
  }

  TugboatSceneInventory? _buildSceneInventoryFromTokenMap({
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required String? route,
    required TugboatSurface surface,
    required bool withBoundsEvidence,
  }) {
    final routeKey = _resolveRouteKey(route, tokenMap);
    final viewport = rootRender.size;
    final contentEntries = <TugboatSceneInventoryEntry>[];
    final interactiveByFingerprint = <String, TugboatSceneInventoryEntry>{};
    final seenContentFingerprints = <String>{};
    final hitCache = <String, TugboatTargetAnchor?>{};
    final evidence = withBoundsEvidence ? _BoundsEvidence(rootRender) : null;
    final loading = withBoundsEvidence
        ? _LoadingEvidence.capture(rootKey.currentContext)
        : null;

    for (final element in tokenMap.includedElements) {
      _addInventoryElement(
        element: element,
        tokenMap: tokenMap,
        rootRender: rootRender,
        viewport: viewport,
        evidence: evidence,
        loading: loading,
        route: route,
        routeKey: routeKey,
        hitCache: hitCache,
        contentEntries: contentEntries,
        interactiveByFingerprint: interactiveByFingerprint,
        seenContentFingerprints: seenContentFingerprints,
      );
    }

    final elements = [...interactiveByFingerprint.values, ...contentEntries];
    if (elements.isEmpty) return null;

    return _inventoryFromElements(
      routeKey: routeKey,
      elements: elements,
      surface: surface,
      viewport: evidence == null ? null : _viewportFor(rootRender),
      scroll: evidence == null ? null : _primaryScrollFor(tokenMap, rootRender),
      loading: _loadingSummary(loading, elements),
    );
  }

  void _addInventoryElement({
    required Element element,
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required Size viewport,
    required _BoundsEvidence? evidence,
    required _LoadingEvidence? loading,
    required String? route,
    required String routeKey,
    required Map<String, TugboatTargetAnchor?> hitCache,
    required List<TugboatSceneInventoryEntry> contentEntries,
    required Map<String, TugboatSceneInventoryEntry> interactiveByFingerprint,
    required Set<String> seenContentFingerprints,
  }) {
    if (!tokenMap.tokens.containsKey(element)) return;
    final widget = element.widget;
    final actionable = tokenMap.isActionable[element] == true;
    if (!_isInventoryCandidate(
      widget,
      actionable,
      element,
      rootRender,
      viewport,
    )) {
      return;
    }
    final structuralPath = _pathFor(element, tokenMap);
    final rect = _paintRectInRoot(element, rootRender);
    if (rect == null) return;
    final bounds = TugboatNormalizedBounds.fromRect(rect, viewport);
    final visibleFraction = evidence?.visibleFractionFor(element, rect);
    final flags = loading?.flagsFor(element);
    final placeholder = flags?.placeholder ?? false;
    if (actionable) {
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
        visibleFraction: visibleFraction,
      );
      if (result != null) {
        _accumulateInteractiveEntry(
          interactiveByFingerprint,
          result.entry.copyWith(
            placeholder: placeholder,
            busy: (flags?.busy ?? false) && result.entry.enabled != false,
          ),
          result.structuralFingerprint,
        );
      }
      return;
    }
    _addContentInventoryEntry(
      contentEntries,
      seenContentFingerprints,
      widget,
      structuralPath,
      bounds,
      routeKey,
      visibleFraction,
      placeholder: placeholder,
    );
  }

  bool _isInventoryCandidate(
    Widget widget,
    bool actionable,
    Element element,
    RenderBox rootRender,
    Size viewport,
  ) =>
      actionable ||
      widget is Image ||
      (widget is Text &&
          _isLargeTextBounds(_boundsForElement(element, rootRender, viewport)));

  void _addContentInventoryEntry(
    List<TugboatSceneInventoryEntry> contentEntries,
    Set<String> seenContentFingerprints,
    Widget widget,
    String structuralPath,
    TugboatNormalizedBounds bounds,
    String routeKey,
    double? visibleFraction, {
    required bool placeholder,
  }) {
    final fingerprint = _fingerprintForParts({
      'routeKey': routeKey,
      'path': structuralPath,
    });
    if (fingerprint.isEmpty || !seenContentFingerprints.add(fingerprint)) {
      return;
    }
    contentEntries.add(
      TugboatSceneInventoryEntry(
        fingerprint: fingerprint,
        canonicalPath: structuralPath,
        widgetType: _widgetName(widget),
        role: 'display',
        boundsNorm: bounds,
        tier: 'content',
        visibleFraction: visibleFraction,
        placeholder: placeholder,
      ),
    );
  }

  TugboatSceneInventory _inventoryFromElements({
    required String routeKey,
    required List<TugboatSceneInventoryEntry> elements,
    required TugboatSurface surface,
    TugboatInventoryViewport? viewport,
    TugboatInventoryScroll? scroll,
    TugboatInventoryLoading? loading,
  }) {
    final fingerprints = elements.map((entry) => entry.fingerprint).toList()
      ..sort();
    final inventoryHash = tugboatLabelHash(fingerprints.join('|'));

    return TugboatSceneInventory(
      inventoryHash: inventoryHash,
      routeKey: routeKey,
      elements: elements,
      surface: surface,
      viewport: viewport,
      scroll: scroll,
      loading: loading,
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
      placeholder: existing.placeholder || entry.placeholder,
      busy: existing.busy || entry.busy,
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

  /// Replaces a nested Flutter hit-target alias with the inventory control's
  /// primary identity. This keeps taps on different regions of one control
  /// consistent in exploration and production capture.
  TugboatTargetAnchor? _normalizeTargetToInventory({
    required TugboatTargetAnchor? target,
    required TugboatSceneInventory? inventory,
  }) {
    final fingerprint = target?.fingerprint;
    if (!_canNormalizeInventoryTarget(target, fingerprint, inventory)) {
      return target;
    }
    final entry = _inventoryAliasEntry(inventory!, fingerprint!);
    return entry == null ? target : _targetForInventoryEntry(target!, entry);
  }

  bool _canNormalizeInventoryTarget(
    TugboatTargetAnchor? target,
    String? fingerprint,
    TugboatSceneInventory? inventory,
  ) =>
      target != null &&
      fingerprint != null &&
      fingerprint.isNotEmpty &&
      inventory != null;

  TugboatSceneInventoryEntry? _inventoryAliasEntry(
    TugboatSceneInventory inventory,
    String fingerprint,
  ) {
    for (final entry in inventory.elements) {
      if (entry.fingerprint == fingerprint) return null;
      if (entry.aliases.contains(fingerprint)) return entry;
    }
    return null;
  }

  TugboatTargetAnchor _targetForInventoryEntry(
    TugboatTargetAnchor target,
    TugboatSceneInventoryEntry entry,
  ) => TugboatTargetAnchor(
    schemaVersion: target.schemaVersion,
    widgetType: entry.widgetType ?? target.widgetType,
    role: entry.role ?? target.role,
    fingerprint: entry.fingerprint,
    fingerprintConfidence: target.fingerprintConfidence,
    fingerprintParts: const {},
    tagFingerprint: target.tagFingerprint,
    canonicalPath: entry.canonicalPath,
    relativePosition: target.relativePosition,
    enabled: entry.enabled ?? target.enabled,
    actions: entry.actions.isNotEmpty ? entry.actions : target.actions,
  );

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
    if (!_canSnapPathlessTarget(target, inventory, rootRender)) return target;
    final best = _smallestSnapCandidate(inventory!, tapPosition, rootRender);
    return best == null ? target : _anchorForSnapCandidate(target!, best);
  }

  bool _canSnapPathlessTarget(
    TugboatTargetAnchor? target,
    TugboatSceneInventory? inventory,
    RenderBox rootRender,
  ) =>
      target != null &&
      inventory != null &&
      !(target.canonicalPath?.isNotEmpty ?? false) &&
      rootRender.size.width > 0 &&
      rootRender.size.height > 0;

  TugboatSceneInventoryEntry? _smallestSnapCandidate(
    TugboatSceneInventory inventory,
    Offset tapPosition,
    RenderBox rootRender,
  ) {
    final viewport = rootRender.size;
    final tap = (
      x: tapPosition.dx / viewport.width,
      y: tapPosition.dy / viewport.height,
    );
    final hitArea = _hitLeafAreaNorm(rootRender, tapPosition);
    TugboatSceneInventoryEntry? best;
    var bestArea = double.infinity;
    for (final entry in inventory.elements) {
      if (!_isPathlessSnapCandidate(entry, tap, hitArea)) continue;
      final area = entry.boundsNorm.width * entry.boundsNorm.height;
      if (area < bestArea) {
        bestArea = area;
        best = entry;
      }
    }
    return best;
  }

  TugboatTargetAnchor _anchorForSnapCandidate(
    TugboatTargetAnchor target,
    TugboatSceneInventoryEntry best,
  ) => TugboatTargetAnchor(
    schemaVersion: target.schemaVersion,
    widgetType: best.widgetType ?? target.widgetType,
    role: best.role ?? target.role,
    fingerprint: best.fingerprint,
    fingerprintConfidence: 'low',
    // The fingerprint now describes the inventory element, a different
    // control, so the original anchor's parts and tag alias would be stale;
    // inventory entries carry neither.
    fingerprintParts: const {},
    canonicalPath: best.canonicalPath,
    relativePosition: target.relativePosition,
    enabled: best.enabled ?? target.enabled,
    actions: best.actions.isNotEmpty ? best.actions : target.actions,
  );

  bool _isPathlessSnapCandidate(
    TugboatSceneInventoryEntry entry,
    ({double x, double y}) tap,
    double? hitAreaNorm,
  ) {
    if (entry.tier != 'interactive') return false;
    if (entry.role == null && entry.actions.isEmpty) return false;
    final bounds = entry.boundsNorm;
    if (!_pointIsInBounds(tap.x, tap.y, bounds)) return false;
    return hitAreaNorm == null ||
        bounds.width * bounds.height >= hitAreaNorm * 0.5;
  }

  bool _pointIsInBounds(double x, double y, TugboatNormalizedBounds bounds) =>
      x >= bounds.left &&
      x <= bounds.left + bounds.width &&
      y >= bounds.top &&
      y <= bounds.top + bounds.height;

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
    required String? route,
    required TugboatSurface surface,
    required bool withBoundsEvidence,
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

    return _inventoryWithEntry(
      inventory: inventory,
      entry: injectedEntry,
      routeKey: routeKey,
      surface: surface,
      viewport: _injectedViewport(inventory, rootRender, withBoundsEvidence),
      loading: _injectedLoading(inventory, withBoundsEvidence),
    );
  }

  /// The loading summary of an inventory with the tap target injected. The
  /// injected entry is never a placeholder and adds no busy control. When
  /// there was no inventory, only the progress-indicator count is walked.
  TugboatInventoryLoading? _injectedLoading(
    TugboatSceneInventory? inventory,
    bool withBoundsEvidence,
  ) {
    if (inventory != null) return inventory.loading;
    if (!withBoundsEvidence) return null;
    final progress =
        _LoadingEvidence.capture(rootKey.currentContext)?.progressIndicators ??
        0;
    return TugboatInventoryLoading(
      progressIndicators: progress,
      placeholders: 0,
      busyControls: 0,
    );
  }

  TugboatSceneInventory _inventoryWithEntry({
    required TugboatSceneInventory? inventory,
    required TugboatSceneInventoryEntry entry,
    required String routeKey,
    required TugboatSurface surface,
    required TugboatInventoryViewport? viewport,
    required TugboatInventoryLoading? loading,
  }) => _inventoryFromElements(
    routeKey: inventory?.routeKey ?? routeKey,
    elements: [
      ...(inventory?.elements ?? const <TugboatSceneInventoryEntry>[]),
      entry,
    ],
    surface: inventory?.surface ?? surface,
    viewport: viewport,
    scroll: inventory?.scroll,
    loading: loading,
  );

  /// The viewport an inventory with the injected tap target carries: its own,
  /// or, when the target is the inventory's only element, the boundary's frame.
  TugboatInventoryViewport? _injectedViewport(
    TugboatSceneInventory? inventory,
    RenderBox rootRender,
    bool withBoundsEvidence,
  ) => inventory == null && withBoundsEvidence
      ? _viewportFor(rootRender)
      : inventory?.viewport;

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
    required double? visibleFraction,
  }) {
    final structuralFingerprint = _fingerprintForParts({
      'routeKey': routeKey,
      'path': structuralPath,
    });

    final center = _inventoryEntryCenter(bounds, viewport);
    // Hit-test once per distinct center (cached). Wrappers that resolve to the
    // same actionable descendant still run through so their structural
    // fingerprints become aliases for edge taps that land on the wrapper.
    final resolved = _cachedInventoryTarget(
      center,
      route,
      tokenMap,
      rootRender,
      hitCache,
    );
    final resolvedEntry = _resolvedInteractiveInventoryEntry(
      resolved,
      structuralPath,
      widget,
      bounds,
      structuralFingerprint,
      visibleFraction,
    );
    if (resolvedEntry != null) return resolvedEntry;

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
        visibleFraction: visibleFraction,
      ),
      structuralFingerprint: structuralFingerprint,
    );
  }

  Offset _inventoryEntryCenter(TugboatNormalizedBounds bounds, Size viewport) =>
      Offset(
        (bounds.left + bounds.width / 2) * viewport.width,
        (bounds.top + bounds.height / 2) * viewport.height,
      );

  TugboatTargetAnchor? _cachedInventoryTarget(
    Offset center,
    String? route,
    _TokenMap tokenMap,
    RenderBox rootRender,
    Map<String, TugboatTargetAnchor?> hitCache,
  ) => hitCache.putIfAbsent(
    '${center.dx}|${center.dy}',
    () => _targetAtWithTokenMap(
      center,
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
    ),
  );

  ({TugboatSceneInventoryEntry entry, String structuralFingerprint})?
  _resolvedInteractiveInventoryEntry(
    TugboatTargetAnchor? resolved,
    String structuralPath,
    Widget widget,
    TugboatNormalizedBounds bounds,
    String structuralFingerprint,
    double? visibleFraction,
  ) {
    final fingerprint = resolved?.fingerprint;
    final path = resolved?.canonicalPath;
    if (!_resolvedPathMatches(fingerprint, path, structuralPath)) return null;
    return (
      entry: TugboatSceneInventoryEntry(
        fingerprint: fingerprint!,
        canonicalPath: path!,
        widgetType: resolved?.widgetType ?? _widgetName(widget),
        role: resolved?.role,
        actions: resolved?.actions ?? const [],
        enabled: resolved?.enabled,
        boundsNorm: bounds,
        tier: 'interactive',
        visibleFraction: visibleFraction,
      ),
      structuralFingerprint: structuralFingerprint,
    );
  }

  bool _resolvedPathMatches(
    String? fingerprint,
    String? path,
    String structuralPath,
  ) =>
      fingerprint != null &&
      fingerprint.isNotEmpty &&
      path != null &&
      path.isNotEmpty &&
      _pathsOnSameChain(structuralPath, path);

  bool _pathsOnSameChain(String leftPath, String rightPath) {
    return leftPath.startsWith(rightPath) || rightPath.startsWith(leftPath);
  }

  bool _isLargeTextBounds(TugboatNormalizedBounds? bounds) {
    if (bounds == null) return false;
    return bounds.width * bounds.height >= _largeTextAreaThreshold;
  }
}
