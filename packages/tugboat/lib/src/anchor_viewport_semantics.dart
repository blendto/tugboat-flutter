part of 'anchors.dart';

extension TugboatViewportSemanticsApi on AnchorResolver {
  /// Builds a viewport semantic map from Flutter semantics,
  /// enriched with scene inventory fingerprints when overlap is clear.
  TugboatViewportSemanticMap? buildViewportSemanticMap({
    required TugboatSceneInventory inventory,
    bool allowTransientSemanticsHandle = true,
  }) {
    final rootContext = rootKey.currentContext;
    final rootRender = rootContext?.findRenderObject();
    if (rootContext is! Element ||
        rootRender is! RenderBox ||
        !rootRender.hasSize) {
      return null;
    }

    final viewport = rootRender.size;
    if (viewport.width <= 0 || viewport.height <= 0) return null;
    final devicePixelRatio = View.maybeOf(rootContext)?.devicePixelRatio ?? 1.0;

    final initialPipelineOwner =
        rootRender.owner ?? RendererBinding.instance.rootPipelineOwner;
    final semanticsAlreadyEnabled =
        initialPipelineOwner.semanticsOwner != null ||
        RendererBinding.instance.rootPipelineOwner.semanticsOwner != null;
    final scheduler = SchedulerBinding.instance;
    final canFlushNewSemanticsTree =
        !semanticsAlreadyEnabled &&
        allowTransientSemanticsHandle &&
        scheduler.schedulerPhase == SchedulerPhase.idle &&
        !scheduler.hasScheduledFrame;
    final semanticsHandle =
        semanticsAlreadyEnabled || !allowTransientSemanticsHandle
        ? null
        : SemanticsBinding.instance.ensureSemantics();
    try {
      final pipelineOwner =
          rootRender.owner ?? RendererBinding.instance.rootPipelineOwner;
      final nodes = <TugboatViewportSemanticNode>[];
      SemanticsNode? rootNode;
      final semanticsOwner =
          pipelineOwner.semanticsOwner ??
          RendererBinding.instance.rootPipelineOwner.semanticsOwner;
      if (semanticsOwner != null) {
        // A transient handle needs one synchronous flush before it is disposed.
        // Only do that when no frame was pending before semantics were enabled.
        // A pending frame can contain dirty layout or paint state, where forcing
        // a semantics flush can assert. In that case, read the last stable tree
        // and let inventory fallback cover nodes until Flutter's next flush.
        if (semanticsHandle != null && canFlushNewSemanticsTree) {
          pipelineOwner.flushSemantics();
        }
        rootNode = semanticsOwner.rootSemanticsNode;
      }
      void walk(SemanticsNode node, {required Matrix4 transformToRoot}) {
        if (node.id != 0) {
          final built = _viewportSemanticNodeFromSemantics(
            node: node,
            transformToRoot: transformToRoot,
            rootRender: rootRender,
            viewport: viewport,
            devicePixelRatio: devicePixelRatio,
            inventory: inventory,
          );
          if (built != null) {
            nodes.add(built);
          }
        }
        node.visitChildren((SemanticsNode child) {
          final childTransform = Matrix4.copy(transformToRoot);
          if (child.transform != null) {
            childTransform.multiply(child.transform!);
          }
          walk(child, transformToRoot: childTransform);
          return true;
        });
      }

      if (rootNode != null) {
        walk(rootNode, transformToRoot: Matrix4.identity());
      }
      _addInventoryFallbackSemanticNodes(nodes, inventory);
      final filteredCount = _normalizeViewportSemanticNodes(nodes);
      if (nodes.isEmpty) return null;

      nodes.sort(_compareViewportSemanticNodes);
      final summary = _viewportSemanticMapSummary(
        nodes,
        filteredCount: filteredCount,
      );
      final mapHash = _viewportSemanticMapHash(nodes);

      return TugboatViewportSemanticMap(
        routeKey: inventory.routeKey,
        viewport: viewport,
        nodes: nodes,
        summary: summary,
        mapHash: mapHash,
      );
    } finally {
      semanticsHandle?.dispose();
    }
  }

  /// Resolves a tap point against [map], preferring enabled actionable nodes,
  /// then smallest bounds, then deepest node.
  TugboatViewportSemanticResolution resolveTapOnViewportSemanticMap({
    required Offset tapPosition,
    required TugboatViewportSemanticMap map,
    required RenderBox rootRender,
    TugboatSceneInventory? inventory,
    bool enableInventoryFallback = false,
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
        .where((node) => node.isActionable && node.enabled != false)
        .toList();
    if (enabledActionable.isNotEmpty) {
      final winner = _pickViewportSemanticWinner(enabledActionable);
      if (enableInventoryFallback &&
          winner.linkedFingerprint?.isNotEmpty != true &&
          inventory != null) {
        final fallback = _safeInventoryCandidateAtTap(
          tapPosition: tapPosition,
          semanticNode: winner,
          inventory: inventory,
          rootRender: rootRender,
        );
        if (fallback != null) {
          return _resolutionForNode(
            node: winner,
            status: 'matched_inventory_fallback',
            linkedFingerprint: fallback.fingerprint,
            linkedCanonicalPath: fallback.canonicalPath,
            fingerprintConfidence: 'low',
          );
        }
      }
      return _resolutionForNode(node: winner, status: 'matched_actionable');
    }

    final disabledActionable = candidates
        .where((node) => node.isActionable && node.enabled == false)
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
    required Matrix4 transformToRoot,
    required RenderBox rootRender,
    required Size viewport,
    required double devicePixelRatio,
    required TugboatSceneInventory inventory,
  }) {
    if (node.isInvisible) return null;

    final data = node.getSemanticsData();
    if (node.rect.isEmpty) return null;

    final actions = _semanticsActionsFromData(data);
    final role = _semanticsRoleFromData(data);
    // Nodes that don't declare an enabled state are unknown (null), not
    // disabled; treating them as disabled skews tap resolution.
    final bool? enabled = semanticsEnabledFromFlags(data.flagsCollection);
    final scrollable = _semanticsNodeIsScrollable(data);
    final hasReadableContent =
        data.label.isNotEmpty || data.value.isNotEmpty || data.hint.isNotEmpty;
    if (actions.isEmpty &&
        role == null &&
        !scrollable &&
        !data.flagsCollection.isHeader &&
        !data.flagsCollection.isImage &&
        !data.flagsCollection.isTextField &&
        !hasReadableContent) {
      return null;
    }

    final boundsNorm = _bestSemanticBoundsCandidate(
      rawRect: node.rect,
      transformToRoot: transformToRoot,
      rootRender: rootRender,
      viewport: viewport,
      devicePixelRatio: devicePixelRatio,
    );
    if (boundsNorm == null) return null;

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
      source: 'semantic',
      role: role,
      actions: actions,
      enabled: enabled,
      boundsNorm: link?.boundsNorm ?? boundsNorm,
      scrollable: scrollable,
      linkedFingerprint: link?.fingerprint,
      linkedCanonicalPath: link?.canonicalPath,
    );
  }

  void _addInventoryFallbackSemanticNodes(
    List<TugboatViewportSemanticNode> nodes,
    TugboatSceneInventory inventory,
  ) {
    var syntheticIndex = 0;
    for (final entry in inventory.elements) {
      if (_inventoryEntryCoveredBySemanticNode(entry, nodes)) continue;
      nodes.add(
        TugboatViewportSemanticNode(
          nodeId: -1 - syntheticIndex,
          depth: 0,
          siblingIndex: syntheticIndex,
          source: 'inventory',
          role: entry.role,
          actions: entry.actions,
          enabled: entry.enabled,
          boundsNorm: entry.boundsNorm,
          scrollable: entry.role == 'scrollable',
          linkedFingerprint: entry.fingerprint,
          linkedCanonicalPath: entry.canonicalPath,
        ),
      );
      syntheticIndex++;
    }
  }

  int _normalizeViewportSemanticNodes(List<TugboatViewportSemanticNode> nodes) {
    var filteredCount = 0;
    for (var index = nodes.length - 1; index >= 0; index--) {
      final node = nodes[index];
      final clamped = node.boundsNorm.clampToViewport();
      final shouldDrop = _shouldDropViewportSemanticNode(node, clamped);
      if (shouldDrop) {
        nodes.removeAt(index);
        filteredCount++;
      } else if (clamped != node.boundsNorm) {
        nodes[index] = node.copyWith(boundsNorm: clamped);
      }
    }
    return filteredCount;
  }

  bool _shouldDropViewportSemanticNode(
    TugboatViewportSemanticNode node,
    TugboatNormalizedBounds clampedBounds,
  ) {
    if (node.linkedFingerprint?.isNotEmpty == true) return false;
    if (clampedBounds.width <= 0 || clampedBounds.height <= 0) return true;
    final original = node.boundsNorm;
    final touchesEdge =
        original.left < 0 ||
        original.top < 0 ||
        original.left + original.width > 1 ||
        original.top + original.height > 1;
    final tinyArea = clampedBounds.width * clampedBounds.height < 0.002;
    final tinyHeight = clampedBounds.height < 0.015;
    if (touchesEdge && (tinyArea || tinyHeight)) return true;
    if (node.isActionable && node.enabled != false) return false;
    return false;
  }

  bool _inventoryEntryCoveredBySemanticNode(
    TugboatSceneInventoryEntry entry,
    List<TugboatViewportSemanticNode> nodes,
  ) {
    for (final node in nodes) {
      if (node.linkedFingerprint == entry.fingerprint ||
          entry.aliases.contains(node.linkedFingerprint)) {
        return true;
      }
      final overlap = _boundsOverlapRatio(node.boundsNorm, entry.boundsNorm);
      if (overlap < 0.8) continue;
      if (!_inventoryRoleCompatible(node.role, entry.role)) continue;
      if (!_inventoryActionsCompatible(node.actions, entry.actions)) continue;
      return true;
    }
    return false;
  }

  TugboatNormalizedBounds? _bestSemanticBoundsCandidate({
    required Rect rawRect,
    required Matrix4 transformToRoot,
    required RenderBox rootRender,
    required Size viewport,
    required double devicePixelRatio,
  }) {
    // The accumulated child-transform chain maps node-local rects into the
    // root semantics space (physical pixels: the device-pixel-ratio scale is
    // carried on the render view's child semantics transform, which the walk
    // includes). Physical -> logical global -> boundary-local is therefore
    // deterministic; no candidate voting is needed.
    final transformed = MatrixUtils.transformRect(transformToRoot, rawRect);
    final logical = _scaleRect(transformed, 1 / devicePixelRatio);
    final rootLocal = Rect.fromPoints(
      rootRender.globalToLocal(logical.topLeft),
      rootRender.globalToLocal(logical.bottomRight),
    );
    if (rootLocal.isEmpty) return null;
    final boundsNorm = TugboatNormalizedBounds.fromRect(rootLocal, viewport);
    if (boundsNorm.width <= 0 || boundsNorm.height <= 0) return null;
    if (!_boundsIntersectsViewport(boundsNorm)) return null;
    return boundsNorm;
  }

  Rect _scaleRect(Rect rect, double scale) {
    return Rect.fromLTRB(
      rect.left * scale,
      rect.top * scale,
      rect.right * scale,
      rect.bottom * scale,
    );
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
    if (data.label.isNotEmpty ||
        data.value.isNotEmpty ||
        data.hint.isNotEmpty) {
      return 'text';
    }
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
      if (actions.isEmpty && entry.actions.isNotEmpty) continue;
      if ((role == 'text' || role == 'display') &&
          entry.tier == 'interactive') {
        continue;
      }
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
    if (semanticRole == 'text' && inventoryRole == 'display') return true;
    if (semanticRole == 'display' && inventoryRole == 'text') return true;
    return false;
  }

  bool _inventoryActionsCompatible(
    List<String> semanticActions,
    List<String> inventoryActions,
  ) {
    if (semanticActions.isEmpty || inventoryActions.isEmpty) return true;
    return semanticActions
        .toSet()
        .intersection(inventoryActions.toSet())
        .isNotEmpty;
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
    final sorted = [...candidates]..sort(_compareViewportSemanticCandidates);
    return sorted.first;
  }

  /// Finds a safe inventory identity for an actionable semantic node that has
  /// no direct fingerprint link. The inventory already excludes controls
  /// hidden by blocking overlays. The hit-area guard also rejects a small
  /// control under a larger surface that received the pointer.
  TugboatSceneInventoryEntry? _safeInventoryCandidateAtTap({
    required Offset tapPosition,
    required TugboatViewportSemanticNode semanticNode,
    required TugboatSceneInventory inventory,
    required RenderBox rootRender,
  }) {
    final viewport = rootRender.size;
    if (viewport.width <= 0 || viewport.height <= 0) return null;
    final localPoint = rootRender.globalToLocal(tapPosition);
    final nx = localPoint.dx / viewport.width;
    final ny = localPoint.dy / viewport.height;
    final hitAreaNorm = _hitLeafAreaNorm(rootRender, tapPosition);

    TugboatSceneInventoryEntry? best;
    var bestArea = double.infinity;
    for (final entry in inventory.elements) {
      if (entry.tier != 'interactive' || entry.enabled == false) continue;
      if (entry.actions.isEmpty ||
          !_inventoryActionsCompatible(semanticNode.actions, entry.actions)) {
        continue;
      }
      final bounds = entry.boundsNorm;
      if (!_normalizedPointInBounds(nx, ny, bounds)) continue;
      final area = bounds.width * bounds.height;
      if (area <= 0) continue;
      if (hitAreaNorm != null && area < hitAreaNorm * 0.5) continue;
      if (area < bestArea) {
        bestArea = area;
        best = entry;
      }
    }
    return best;
  }

  int _compareViewportSemanticCandidates(
    TugboatViewportSemanticNode left,
    TugboatViewportSemanticNode right,
  ) {
    final leftArea = left.boundsNorm.width * left.boundsNorm.height;
    final rightArea = right.boundsNorm.width * right.boundsNorm.height;
    final areaCompare = leftArea.compareTo(rightArea);
    if (areaCompare != 0) return areaCompare;
    final depthCompare = right.depth.compareTo(left.depth);
    if (depthCompare != 0) return depthCompare;
    return _compareViewportSemanticNodes(left, right);
  }

  int _compareViewportSemanticNodes(
    TugboatViewportSemanticNode left,
    TugboatViewportSemanticNode right,
  ) {
    final leftTop = left.boundsNorm.top.compareTo(right.boundsNorm.top);
    if (leftTop != 0) return leftTop;
    final leftLeft = left.boundsNorm.left.compareTo(right.boundsNorm.left);
    if (leftLeft != 0) return leftLeft;
    final depthCompare = left.depth.compareTo(right.depth);
    if (depthCompare != 0) return depthCompare;
    final siblingCompare = (left.siblingIndex ?? -1).compareTo(
      right.siblingIndex ?? -1,
    );
    if (siblingCompare != 0) return siblingCompare;
    final roleCompare = (left.role ?? '').compareTo(right.role ?? '');
    if (roleCompare != 0) return roleCompare;
    return (left.linkedFingerprint ?? '').compareTo(
      right.linkedFingerprint ?? '',
    );
  }

  TugboatViewportSemanticResolution _resolutionForNode({
    required TugboatViewportSemanticNode node,
    required String status,
    String? linkedFingerprint,
    String? linkedCanonicalPath,
    String? fingerprintConfidence,
  }) {
    return TugboatViewportSemanticResolution(
      status: status,
      nodeId: node.nodeId,
      role: node.role,
      actions: node.actions,
      boundsNorm: node.boundsNorm,
      linkedFingerprint: linkedFingerprint ?? node.linkedFingerprint,
      linkedCanonicalPath: linkedCanonicalPath ?? node.linkedCanonicalPath,
      fingerprintConfidence: fingerprintConfidence,
      enabled: node.enabled,
    );
  }

  Map<String, int> _viewportSemanticMapSummary(
    List<TugboatViewportSemanticNode> nodes, {
    int filteredCount = 0,
  }) {
    var actionableCount = 0;
    var scrollableCount = 0;
    var disabledCount = 0;
    var linkedCount = 0;
    for (final node in nodes) {
      if (node.isActionable) actionableCount++;
      if (node.scrollable) scrollableCount++;
      if (node.enabled == false) disabledCount++;
      if (node.linkedFingerprint?.isNotEmpty == true) linkedCount++;
    }
    return {
      'totalNodes': nodes.length,
      'actionableCount': actionableCount,
      'scrollableCount': scrollableCount,
      'disabledCount': disabledCount,
      'linkedCount': linkedCount,
      'semanticCount': nodes.where((node) => node.source == 'semantic').length,
      'inventoryCount': nodes
          .where((node) => node.source == 'inventory')
          .length,
      'filteredCount': filteredCount,
    };
  }

  String _viewportSemanticMapHash(List<TugboatViewportSemanticNode> nodes) {
    final parts = nodes.map((node) {
      final bounds = node.boundsNorm;
      return [
        node.depth,
        node.siblingIndex ?? -1,
        node.source,
        node.role ?? '',
        node.actions.join(','),
        node.enabled ?? true,
        bounds.left.toStringAsFixed(3),
        bounds.top.toStringAsFixed(3),
        bounds.width.toStringAsFixed(3),
        bounds.height.toStringAsFixed(3),
        node.scrollable,
        node.linkedFingerprint ?? '',
        node.linkedCanonicalPath ?? '',
      ].join('|');
    }).toList();
    return tugboatLabelHash(parts.join('\n'));
  }
}
