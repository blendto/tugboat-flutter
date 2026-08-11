part of 'anchors.dart';

/// Normalized bounds within the viewport (0–1).
class TugboatNormalizedBounds {
  const TugboatNormalizedBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  factory TugboatNormalizedBounds.fromRect(Rect rect, Size viewport) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      return const TugboatNormalizedBounds(
        left: 0,
        top: 0,
        width: 0,
        height: 0,
      );
    }
    return TugboatNormalizedBounds(
      left: rect.left / viewport.width,
      top: rect.top / viewport.height,
      width: rect.width / viewport.width,
      height: rect.height / viewport.height,
    );
  }

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  TugboatNormalizedBounds clampToViewport() {
    final right = (left + width).clamp(0.0, 1.0);
    final bottom = (top + height).clamp(0.0, 1.0);
    final clampedLeft = left.clamp(0.0, 1.0);
    final clampedTop = top.clamp(0.0, 1.0);
    return TugboatNormalizedBounds(
      left: clampedLeft,
      top: clampedTop,
      width: (right - clampedLeft).clamp(0.0, 1.0),
      height: (bottom - clampedTop).clamp(0.0, 1.0),
    );
  }
}

/// Compact description of the actionable target under a touch.
class TugboatTargetAnchor {
  const TugboatTargetAnchor({
    this.schemaVersion = 1,
    this.widgetType,
    this.role,
    this.fingerprint,
    this.fingerprintConfidence,
    this.tagFingerprint,
    this.fingerprintParts = const {},
    this.canonicalPath,
    this.relativePosition,
    this.enabled,
    this.actions = const [],
  });

  final int schemaVersion;
  final String? widgetType;
  final String? role;
  final String? fingerprint;
  final String? fingerprintConfidence;
  final String? tagFingerprint;

  /// Stable fields used to derive [fingerprint]. Dynamic labels are excluded.
  final Map<String, String> fingerprintParts;

  /// Canonical structural path used to identify this target within its route.
  final String? canonicalPath;
  final String? relativePosition;
  final bool? enabled;
  final List<String> actions;

  Map<String, Object?> toJson() => {
    if (schemaVersion != 1) 'schemaVersion': schemaVersion,
    if (widgetType != null) 'widgetType': widgetType,
    if (role != null) 'role': role,
    if (fingerprint != null && fingerprint!.isNotEmpty)
      'fingerprint': fingerprint,
    if (fingerprintConfidence != null && fingerprintConfidence!.isNotEmpty)
      'fingerprintConfidence': fingerprintConfidence,
    if (tagFingerprint != null && tagFingerprint!.isNotEmpty)
      'tagFingerprint': tagFingerprint,
    if (fingerprintParts.isNotEmpty) 'fingerprintParts': fingerprintParts,
    if (canonicalPath != null && canonicalPath!.isNotEmpty)
      'canonicalPath': canonicalPath,
    if (relativePosition != null) 'relativePosition': relativePosition,
    if (enabled != null) 'enabled': enabled,
    if (actions.isNotEmpty) 'actions': actions,
  };

  @override
  bool operator ==(Object other) =>
      other is TugboatTargetAnchor &&
      schemaVersion == other.schemaVersion &&
      widgetType == other.widgetType &&
      role == other.role &&
      fingerprint == other.fingerprint &&
      fingerprintConfidence == other.fingerprintConfidence &&
      tagFingerprint == other.tagFingerprint &&
      _mapEquals(fingerprintParts, other.fingerprintParts) &&
      canonicalPath == other.canonicalPath &&
      relativePosition == other.relativePosition &&
      enabled == other.enabled &&
      _listEquals(actions, other.actions);

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    widgetType,
    role,
    fingerprint,
    fingerprintConfidence,
    tagFingerprint,
    _stringMapHash(fingerprintParts),
    canonicalPath,
    relativePosition,
    enabled,
    Object.hashAll(actions),
  );
}

/// One salient element in a screen's structural inventory.
class TugboatSceneInventoryEntry {
  const TugboatSceneInventoryEntry({
    required this.fingerprint,
    required this.canonicalPath,
    this.widgetType,
    this.role,
    this.actions = const [],
    this.enabled,
    required this.boundsNorm,
    required this.tier,
    this.aliases = const [],
  });

  final String fingerprint;
  final String canonicalPath;
  final String? widgetType;
  final String? role;
  final List<String> actions;
  final bool? enabled;
  final TugboatNormalizedBounds boundsNorm;
  final String tier;

  /// Alternate structural fingerprints for the same control (wrapper layers).
  final List<String> aliases;

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'canonicalPath': canonicalPath,
    if (widgetType != null) 'widgetType': widgetType,
    if (role != null) 'role': role,
    if (actions.isNotEmpty) 'actions': actions,
    if (enabled != null) 'enabled': enabled,
    'boundsNorm': boundsNorm.toJson(),
    'tier': tier,
    if (aliases.isNotEmpty) 'aliases': aliases,
  };

  TugboatSceneInventoryEntry copyWith({List<String>? aliases}) {
    return TugboatSceneInventoryEntry(
      fingerprint: fingerprint,
      canonicalPath: canonicalPath,
      widgetType: widgetType,
      role: role,
      actions: actions,
      enabled: enabled,
      boundsNorm: boundsNorm,
      tier: tier,
      aliases: aliases ?? this.aliases,
    );
  }
}

/// Structural inventory of salient elements on a settled screen state.
class TugboatSceneInventory {
  const TugboatSceneInventory({
    required this.inventoryHash,
    required this.routeKey,
    required this.elements,
  });

  final String inventoryHash;
  final String routeKey;
  final List<TugboatSceneInventoryEntry> elements;

  Map<String, Object?> toJson() => {
    'inventoryHash': inventoryHash,
    'routeKey': routeKey,
    'elements': elements.map((entry) => entry.toJson()).toList(),
  };
}

/// One semantics-backed node in a viewport semantic map.
class TugboatViewportSemanticNode {
  const TugboatViewportSemanticNode({
    required this.nodeId,
    this.parentId,
    required this.depth,
    this.siblingIndex,
    this.source = 'semantic',
    this.role,
    this.actions = const [],
    this.enabled,
    required this.boundsNorm,
    this.scrollable = false,
    this.linkedFingerprint,
    this.linkedCanonicalPath,
  });

  final int nodeId;
  final int? parentId;
  final int depth;
  final int? siblingIndex;
  final String source;
  final String? role;
  final List<String> actions;
  final bool? enabled;
  final TugboatNormalizedBounds boundsNorm;
  final bool scrollable;
  final String? linkedFingerprint;
  final String? linkedCanonicalPath;

  bool get isActionable => actions.isNotEmpty;

  TugboatViewportSemanticNode copyWith({TugboatNormalizedBounds? boundsNorm}) {
    return TugboatViewportSemanticNode(
      nodeId: nodeId,
      parentId: parentId,
      depth: depth,
      siblingIndex: siblingIndex,
      source: source,
      role: role,
      actions: actions,
      enabled: enabled,
      boundsNorm: boundsNorm ?? this.boundsNorm,
      scrollable: scrollable,
      linkedFingerprint: linkedFingerprint,
      linkedCanonicalPath: linkedCanonicalPath,
    );
  }

  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    if (parentId != null) 'parentId': parentId,
    'depth': depth,
    if (siblingIndex != null) 'siblingIndex': siblingIndex,
    'source': source,
    if (role != null) 'role': role,
    if (actions.isNotEmpty) 'actions': actions,
    if (enabled != null) 'enabled': enabled,
    'boundsNorm': boundsNorm.toJson(),
    if (scrollable) 'scrollable': scrollable,
    if (linkedFingerprint != null) 'linkedFingerprint': linkedFingerprint,
    if (linkedCanonicalPath != null) 'linkedCanonicalPath': linkedCanonicalPath,
  };
}

/// Scroll position attached to a viewport semantic observation.
class TugboatViewportSemanticScrollContext {
  const TugboatViewportSemanticScrollContext({
    required this.trigger,
    this.scrollableFingerprint,
    this.axis,
    this.offset,
    this.offsetNorm,
    this.startOffset,
    this.endOffset,
    this.depth,
    this.observedTopNorm,
    this.observedBottomNorm,
  });

  final String trigger;
  final String? scrollableFingerprint;
  final String? axis;
  final double? offset;
  final double? offsetNorm;
  final double? startOffset;
  final double? endOffset;
  final int? depth;
  final double? observedTopNorm;
  final double? observedBottomNorm;

  String get dedupeKey => [
    trigger,
    scrollableFingerprint ?? '',
    axis ?? '',
    offsetNorm == null ? '' : offsetNorm!.toStringAsFixed(3),
    offset == null ? '' : offset!.round().toString(),
  ].join('|');

  Map<String, Object?> toJson() => {
    'trigger': trigger,
    if (scrollableFingerprint != null)
      'scrollableFingerprint': scrollableFingerprint,
    if (axis != null) 'axis': axis,
    if (offset != null) 'offset': offset,
    if (offsetNorm != null) 'offsetNorm': offsetNorm,
    if (startOffset != null) 'startOffset': startOffset,
    if (endOffset != null) 'endOffset': endOffset,
    if (depth != null) 'depth': depth,
    if (observedTopNorm != null) 'observedTopNorm': observedTopNorm,
    if (observedBottomNorm != null) 'observedBottomNorm': observedBottomNorm,
  };
}

/// Exploration-only viewport semantic map for a settled screen state.
class TugboatViewportSemanticMap {
  const TugboatViewportSemanticMap({
    required this.routeKey,
    required this.viewport,
    required this.nodes,
    required this.summary,
    required this.mapHash,
    this.scrollContext,
  });

  final String routeKey;
  final Size viewport;
  final List<TugboatViewportSemanticNode> nodes;
  final Map<String, int> summary;
  final String mapHash;
  final TugboatViewportSemanticScrollContext? scrollContext;

  TugboatViewportSemanticMap copyWith({
    List<TugboatViewportSemanticNode>? nodes,
    Map<String, int>? summary,
    String? mapHash,
    TugboatViewportSemanticScrollContext? scrollContext,
  }) {
    return TugboatViewportSemanticMap(
      routeKey: routeKey,
      viewport: viewport,
      nodes: nodes ?? this.nodes,
      summary: summary ?? this.summary,
      mapHash: mapHash ?? this.mapHash,
      scrollContext: scrollContext ?? this.scrollContext,
    );
  }

  Map<String, Object?> toJson() => {
    'routeKey': routeKey,
    'viewport': {'width': viewport.width, 'height': viewport.height},
    'nodes': nodes.map((node) => node.toJson()).toList(),
    'summary': summary,
    'mapHash': mapHash,
    if (scrollContext != null) 'scrollContext': scrollContext!.toJson(),
  };
}

/// Multi-viewport semantic evidence observed during a scroll interaction.
class TugboatScrollSemanticSnapshot {
  const TugboatScrollSemanticSnapshot({
    required this.routeKey,
    required this.scrollableFingerprint,
    required this.axis,
    required this.observedSliceCount,
    required this.observedNodeCount,
    required this.observedActionableCount,
    required this.linkedNodeCount,
    required this.observedTopNorm,
    required this.observedBottomNorm,
    required this.snapshotHash,
  });

  final String routeKey;
  final String? scrollableFingerprint;
  final String? axis;
  final int observedSliceCount;
  final int observedNodeCount;
  final int observedActionableCount;
  final int linkedNodeCount;
  final double? observedTopNorm;
  final double? observedBottomNorm;
  final String snapshotHash;

  Map<String, Object?> toJson() => {
    'routeKey': routeKey,
    if (scrollableFingerprint != null)
      'scrollableFingerprint': scrollableFingerprint,
    if (axis != null) 'axis': axis,
    'observedSliceCount': observedSliceCount,
    'observedNodeCount': observedNodeCount,
    'observedActionableCount': observedActionableCount,
    'linkedNodeCount': linkedNodeCount,
    if (observedTopNorm != null) 'observedTopNorm': observedTopNorm,
    if (observedBottomNorm != null) 'observedBottomNorm': observedBottomNorm,
    'snapshotHash': snapshotHash,
  };
}

/// Result of resolving a tap against a viewport semantic map.
class TugboatViewportSemanticResolution {
  const TugboatViewportSemanticResolution({
    required this.status,
    this.nodeId,
    this.role,
    this.actions = const [],
    this.boundsNorm,
    this.linkedFingerprint,
    this.enabled,
  });

  final String status;
  final int? nodeId;
  final String? role;
  final List<String> actions;
  final TugboatNormalizedBounds? boundsNorm;
  final String? linkedFingerprint;
  final bool? enabled;

  Map<String, Object?> toJson() => {
    'status': status,
    if (nodeId != null) 'nodeId': nodeId,
    if (role != null) 'role': role,
    if (actions.isNotEmpty) 'actions': actions,
    if (boundsNorm != null) 'boundsNorm': boundsNorm!.toJson(),
    if (linkedFingerprint != null) 'linkedFingerprint': linkedFingerprint,
    if (enabled != null) 'enabled': enabled,
  };
}
