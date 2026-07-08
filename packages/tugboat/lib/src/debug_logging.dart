import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'anchors.dart';

void tugboatLogViewportSemanticMap(
  TugboatViewportSemanticMap map, {
  int? buildMs,
}) {
  final scroll = map.scrollContext;
  debugPrint(
    '[tugboat] viewport_semantic_map route=${map.routeKey} '
    'buildMs=${buildMs ?? '?'} '
    'state=${map.stateSignature} nodes=${map.summary['totalNodes']} '
    'actionable=${map.summary['actionableCount']} '
    'linked=${map.summary['linkedCount']} '
    'semantic=${map.summary['semanticCount']} '
    'inventory=${map.summary['inventoryCount']} '
    'scrollable=${map.summary['scrollableCount']} '
    'filtered=${map.summary['filteredCount'] ?? 0} '
    'truncated=${map.summary['truncatedCount'] ?? 0} '
    'scroll=${scroll?.trigger ?? 'none'} '
    'scrollFp=${scroll?.scrollableFingerprint ?? 'none'} '
    'offsetNorm=${scroll?.offsetNorm?.toStringAsFixed(3) ?? 'none'} '
    'hash=${map.mapHash}',
  );
  for (final node in map.nodes.take(12)) {
    final bounds = node.boundsNorm;
    debugPrint(
      '[tugboat] viewport_semantic_node '
      'source=${node.source} role=${node.role ?? 'none'} '
      'actions=${node.actions.join(',')} '
      'enabled=${node.enabled ?? true} '
      'bounds=l=${bounds.left.toStringAsFixed(3)},'
      't=${bounds.top.toStringAsFixed(3)},'
      'w=${bounds.width.toStringAsFixed(3)},'
      'h=${bounds.height.toStringAsFixed(3)} '
      'fingerprint=${node.linkedFingerprint ?? 'none'}',
    );
  }
}

void tugboatLogScrollSemanticSnapshot(TugboatScrollSemanticSnapshot snapshot) {
  debugPrint(
    '[tugboat] scroll_semantic_snapshot route=${snapshot.routeKey} '
    'state=${snapshot.stateSignature} '
    'scrollFp=${snapshot.scrollableFingerprint ?? 'none'} '
    'axis=${snapshot.axis ?? 'none'} slices=${snapshot.observedSliceCount} '
    'nodes=${snapshot.observedNodeCount} '
    'actionable=${snapshot.observedActionableCount} '
    'linked=${snapshot.linkedNodeCount} '
    'range=${snapshot.observedTopNorm?.toStringAsFixed(3) ?? 'none'}..'
    '${snapshot.observedBottomNorm?.toStringAsFixed(3) ?? 'none'} '
    'hash=${snapshot.snapshotHash}',
  );
}

void tugboatLogViewportSemanticTapResolution(
  Offset position,
  TugboatViewportSemanticResolution resolution,
) {
  final bounds = resolution.boundsNorm;
  final boundsSummary = bounds == null
      ? 'none'
      : 'l=${bounds.left.toStringAsFixed(3)},'
            't=${bounds.top.toStringAsFixed(3)},'
            'w=${bounds.width.toStringAsFixed(3)},'
            'h=${bounds.height.toStringAsFixed(3)}';
  debugPrint(
    '[tugboat] viewport_semantic_tap '
    'point=(${position.dx.toStringAsFixed(1)},${position.dy.toStringAsFixed(1)}) '
    'status=${resolution.status} role=${resolution.role ?? 'none'} '
    'actions=${resolution.actions.join(',')} bounds=$boundsSummary '
    'fingerprint=${resolution.linkedFingerprint ?? 'none'}',
  );
  if (resolution.status == 'outside_known_ui' ||
      resolution.status == 'matched_non_actionable' ||
      resolution.status == 'matched_disabled') {
    debugPrint(
      '[tugboat] viewport_semantic_anomaly status=${resolution.status} '
      'at=(${position.dx.toStringAsFixed(1)},${position.dy.toStringAsFixed(1)})',
    );
  }
}
