import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'anchors.dart';
import 'debug_logging.dart';
import 'models.dart';
import 'replay_config.dart';

class _ScrollSemanticAccumulator {
  _ScrollSemanticAccumulator({
    required this.gestureSequence,
    required this.routeKey,
    required this.scrollableFingerprint,
    required this.axis,
  });

  final int gestureSequence;
  final String routeKey;
  final String? scrollableFingerprint;
  final String? axis;
  final Map<String, TugboatViewportSemanticMap> slices = {};
}

class _ScrollSemanticSnapshotStats {
  final Set<String> nodeKeys = <String>{};
  int actionableCount = 0;
  int linkedCount = 0;
  double? observedTop;
  double? observedBottom;
}

/// A bounded semantic map and its tap result built without publishing events.
class TugboatViewportTapSnapshot {
  const TugboatViewportTapSnapshot({
    required this.map,
    required this.encodedPayload,
    required this.resolution,
    required this.buildMicros,
  });

  final TugboatViewportSemanticMap? map;
  final Map<String, Object?>? encodedPayload;
  final TugboatViewportSemanticResolution? resolution;
  final int buildMicros;
}

/// Owns viewport-semantic map build / emit / tap resolution for a capture
/// session. Keeps policy branching and scroll stitching out of the controller.
class ViewportSemanticSession {
  ViewportSemanticSession({
    required this.config,
    required this.nextEventId,
    required this.atMs,
    required this.addEvent,
  });

  final TugboatReplayConfig config;
  final String Function(String prefix) nextEventId;
  final int Function() atMs;
  final void Function(TugboatEvent event) addEvent;

  final Set<String> _emittedSemanticMaps = <String>{};
  final Map<String, _ScrollSemanticAccumulator> _scrollSemanticAccumulators =
      {};
  final Set<String> _emittedScrollSemanticSnapshots = <String>{};
  TugboatViewportSemanticMap? _latestMap;
  DateTime? _lastScrollSemanticBuildAt;
  int _scrollGestureSequence = 0;

  TugboatViewportSemanticPolicy get _policy => config.viewportSemanticPolicy;

  bool get engineEnabled => _policy.engineEnabled;

  bool get emitEvents => _policy.emitEvents;

  bool get debugLogs => _policy.debugLogs;

  bool get holdPersistentSemanticsHandle =>
      _policy.holdPersistentSemanticsHandle;

  void clear() {
    _emittedSemanticMaps.clear();
    _scrollSemanticAccumulators.clear();
    _emittedScrollSemanticSnapshots.clear();
    _latestMap = null;
    _lastScrollSemanticBuildAt = null;
    _scrollGestureSequence = 0;
  }

  /// Returns false when a scroll-update semantic rebuild should be skipped.
  bool allowScrollSemanticRebuild(DateTime now, Duration interval) {
    final last = _lastScrollSemanticBuildAt;
    if (last != null && now.difference(last) < interval) {
      return false;
    }
    _lastScrollSemanticBuildAt = now;
    return true;
  }

  void maybeEmit(
    TugboatSceneInventory inventory, {
    required AnchorResolver? resolver,
    TugboatViewportSemanticScrollContext? scrollContext,
  }) {
    try {
      _emit(inventory, resolver: resolver, scrollContext: scrollContext);
    } catch (error, stackTrace) {
      debugPrint(
        '[tugboat] viewport_semantic_map build failed '
        'route=${inventory.routeKey}: '
        '$error\n$stackTrace',
      );
    }
  }

  /// Builds exploration tap semantics without publishing tap-only evidence.
  /// The caller publishes the stored map only after gesture classification.
  TugboatViewportTapSnapshot captureTapSnapshot({
    required Offset position,
    required AnchorResolver? resolver,
    required GlobalKey boundaryKey,
    required TugboatSceneInventory inventory,
  }) {
    if (!engineEnabled || resolver == null) {
      return const TugboatViewportTapSnapshot(
        map: null,
        encodedPayload: null,
        resolution: null,
        buildMicros: 0,
      );
    }
    final rootRender = boundaryKey.currentContext?.findRenderObject();
    if (rootRender is! RenderBox) {
      return const TugboatViewportTapSnapshot(
        map: null,
        encodedPayload: null,
        resolution: null,
        buildMicros: 0,
      );
    }

    final buildStopwatch = Stopwatch()..start();
    final rawMap = resolver.buildViewportSemanticMap(
      inventory: inventory,
      allowTransientSemanticsHandle: !holdPersistentSemanticsHandle,
    );
    if (rawMap == null) {
      buildStopwatch.stop();
      return TugboatViewportTapSnapshot(
        map: null,
        encodedPayload: null,
        resolution: const TugboatViewportSemanticResolution(
          status: 'outside_known_ui',
        ),
        buildMicros: buildStopwatch.elapsedMicroseconds,
      );
    }
    final bounded = _bounded(rawMap);
    final map = bounded?.map;
    final resolution = map == null
        ? const TugboatViewportSemanticResolution(status: 'outside_known_ui')
        : resolver.resolveTapOnViewportSemanticMap(
            tapPosition: position,
            map: map,
            rootRender: rootRender,
            inventory: inventory,
            enableInventoryFallback: true,
          );
    buildStopwatch.stop();
    return TugboatViewportTapSnapshot(
      map: map,
      encodedPayload: bounded?.encodedJson,
      resolution: resolution,
      buildMicros: buildStopwatch.elapsedMicroseconds,
    );
  }

  /// Publishes a stored exploration map after the gesture remains a tap.
  void publishTapSnapshot(TugboatViewportTapSnapshot snapshot) {
    final map = snapshot.map;
    if (map == null) return;
    _latestMap = map;
    if (!emitEvents) return;

    final dedupeKey = '${map.routeKey}|${map.mapHash}|';
    if (!_emittedSemanticMaps.add(dedupeKey)) return;
    addEvent(
      TugboatEvent(
        id: nextEventId('event'),
        atMs: atMs(),
        type: 'viewport_semantic_map',
        data: snapshot.encodedPayload ?? map.toJson(),
      ),
    );
    if (debugLogs) {
      tugboatLogViewportSemanticMap(
        map,
        buildMs: snapshot.buildMicros ~/ Duration.microsecondsPerMillisecond,
      );
    }
  }

  TugboatViewportSemanticResolution? resolveTap({
    required Offset position,
    required AnchorResolver? resolver,
    required GlobalKey boundaryKey,
    TugboatSceneInventory? inventory,
  }) {
    try {
      return _resolveTapUnsafe(
        position: position,
        resolver: resolver,
        boundaryKey: boundaryKey,
        inventory: inventory,
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[tugboat] viewport_semantic_tap resolution failed '
        'point=(${position.dx.toStringAsFixed(1)},'
        '${position.dy.toStringAsFixed(1)}): $error\n$stackTrace',
      );
      return null;
    }
  }

  void _emit(
    TugboatSceneInventory inventory, {
    required AnchorResolver? resolver,
    TugboatViewportSemanticScrollContext? scrollContext,
  }) {
    _beginScrollGestureIfNeeded(inventory, scrollContext);
    if (!engineEnabled || resolver == null) return;
    final built = _buildViewportMap(resolver, inventory, scrollContext);
    if (built == null) return;
    final mapWithContext = built.map;
    final bounded = _bounded(mapWithContext);
    if (bounded == null) return;
    final map = bounded.map;
    final encodedPayload = bounded.encodedJson;

    _latestMap = map;
    // tapResolutionOnly: keep the map as a device-local lookup table.
    if (!emitEvents) return;

    final dedupeKey =
        '${map.routeKey}|${map.mapHash}|${map.scrollContext?.dedupeKey ?? ''}';
    if (_emittedSemanticMaps.add(dedupeKey)) {
      addEvent(
        TugboatEvent(
          id: nextEventId('event'),
          atMs: atMs(),
          type: 'viewport_semantic_map',
          data: encodedPayload ?? map.toJson(),
        ),
      );
      if (debugLogs) {
        tugboatLogViewportSemanticMap(map, buildMs: built.buildMs);
      }
    }
    // A new scroll gesture can revisit a slice that was already published.
    // Keep gesture accumulation independent from event-level map deduplication.
    _recordScrollSemanticSlice(map);
  }

  void _beginScrollGestureIfNeeded(
    TugboatSceneInventory inventory,
    TugboatViewportSemanticScrollContext? scroll,
  ) {
    if (scroll?.trigger == 'scroll_start') {
      _beginScrollSemanticGesture(
        routeKey: inventory.routeKey,
        scroll: scroll!,
      );
    }
  }

  ({TugboatViewportSemanticMap map, int buildMs})? _buildViewportMap(
    AnchorResolver resolver,
    TugboatSceneInventory inventory,
    TugboatViewportSemanticScrollContext? scrollContext,
  ) {
    final stopwatch = Stopwatch()..start();
    final rawMap = resolver.buildViewportSemanticMap(
      inventory: inventory,
      allowTransientSemanticsHandle: !holdPersistentSemanticsHandle,
    );
    stopwatch.stop();
    if (rawMap == null) {
      _logUnavailableViewportMap(inventory);
      return null;
    }
    return (
      map: rawMap.copyWith(scrollContext: scrollContext),
      buildMs: stopwatch.elapsedMilliseconds,
    );
  }

  void _logUnavailableViewportMap(TugboatSceneInventory inventory) {
    if (debugLogs) {
      debugPrint(
        '[tugboat] viewport_semantic_map skipped '
        'route=${inventory.routeKey} reason=empty_or_unavailable_semantics',
      );
    }
  }

  ({TugboatViewportSemanticMap map, Map<String, Object?>? encodedJson})?
  _bounded(TugboatViewportSemanticMap map) {
    final maxNodes = config.viewportSemanticMapMaxNodes;
    final maxBytes = config.viewportSemanticMapMaxBytes;
    var bounded = map;
    if (maxNodes > 0 && bounded.nodes.length > maxNodes) {
      final sorted = [...bounded.nodes]
        ..sort((left, right) {
          final linkedCompare =
              (right.linkedFingerprint?.isNotEmpty == true ? 1 : 0).compareTo(
                left.linkedFingerprint?.isNotEmpty == true ? 1 : 0,
              );
          if (linkedCompare != 0) return linkedCompare;
          final actionableCompare = (right.isActionable ? 1 : 0).compareTo(
            left.isActionable ? 1 : 0,
          );
          if (actionableCompare != 0) return actionableCompare;
          return left.depth.compareTo(right.depth);
        });
      final nodes = sorted.take(maxNodes).toList()
        ..sort((left, right) => left.nodeId.compareTo(right.nodeId));
      final summary = Map<String, int>.from(bounded.summary)
        ..['totalNodes'] = nodes.length
        ..['truncatedCount'] = bounded.nodes.length - nodes.length;
      bounded = bounded.copyWith(nodes: nodes, summary: summary);
    }
    Map<String, Object?>? encoded;
    if (maxBytes > 0) {
      encoded = Map<String, Object?>.from(bounded.toJson());
      final encodedLength = jsonEncode(encoded).length;
      if (encodedLength > maxBytes) {
        if (debugLogs) {
          debugPrint(
            '[tugboat] viewport_semantic_map skipped '
            'route=${map.routeKey} '
            'reason=payload_too_large bytes=$encodedLength '
            'limit=$maxBytes',
          );
        }
        return null;
      }
    }
    return (map: bounded, encodedJson: encoded);
  }

  void _recordScrollSemanticSlice(TugboatViewportSemanticMap map) {
    final scroll = map.scrollContext;
    if (scroll == null) return;
    final accumulatorKey = [
      map.routeKey,
      scroll.scrollableFingerprint ?? 'unknown',
      scroll.axis ?? 'unknown',
    ].join('|');
    var accumulator = _scrollSemanticAccumulators[accumulatorKey];
    if (accumulator == null) {
      accumulator = _ScrollSemanticAccumulator(
        gestureSequence: ++_scrollGestureSequence,
        routeKey: map.routeKey,
        scrollableFingerprint: scroll.scrollableFingerprint,
        axis: scroll.axis,
      );
      _scrollSemanticAccumulators[accumulatorKey] = accumulator;
    }
    accumulator.slices[scroll.dedupeKey] = map;
    if (accumulator.slices.length < 2) return;
    final snapshot = _buildScrollSemanticSnapshot(accumulator);
    final snapshotKey =
        '${accumulator.gestureSequence}|${snapshot.snapshotHash}';
    if (!_emittedScrollSemanticSnapshots.add(snapshotKey)) return;
    addEvent(
      TugboatEvent(
        id: nextEventId('event'),
        atMs: atMs(),
        type: 'scroll_semantic_snapshot',
        data: snapshot.toJson(),
      ),
    );
    if (debugLogs) {
      tugboatLogScrollSemanticSnapshot(snapshot);
    }
  }

  void _beginScrollSemanticGesture({
    required String routeKey,
    required TugboatViewportSemanticScrollContext scroll,
  }) {
    final accumulatorKey = [
      routeKey,
      scroll.scrollableFingerprint ?? 'unknown',
      scroll.axis ?? 'unknown',
    ].join('|');
    _scrollSemanticAccumulators[accumulatorKey] = _ScrollSemanticAccumulator(
      gestureSequence: ++_scrollGestureSequence,
      routeKey: routeKey,
      scrollableFingerprint: scroll.scrollableFingerprint,
      axis: scroll.axis,
    );
  }

  TugboatScrollSemanticSnapshot _buildScrollSemanticSnapshot(
    _ScrollSemanticAccumulator accumulator,
  ) {
    final stats = _ScrollSemanticSnapshotStats();
    for (final map in accumulator.slices.values) {
      _collectScrollSemanticSlice(stats, map);
    }
    final sortedKeys = stats.nodeKeys.toList()..sort();
    final hash = tugboatLabelHash(
      [
        accumulator.routeKey,
        accumulator.scrollableFingerprint ?? '',
        accumulator.axis ?? '',
        accumulator.slices.length,
        sortedKeys.join('\n'),
      ].join('|'),
    );
    return TugboatScrollSemanticSnapshot(
      routeKey: accumulator.routeKey,
      scrollableFingerprint: accumulator.scrollableFingerprint,
      axis: accumulator.axis,
      observedSliceCount: accumulator.slices.length,
      observedNodeCount: sortedKeys.length,
      observedActionableCount: stats.actionableCount,
      linkedNodeCount: stats.linkedCount,
      observedTopNorm: stats.observedTop,
      observedBottomNorm: stats.observedBottom,
      snapshotHash: hash,
    );
  }

  void _collectScrollSemanticSlice(
    _ScrollSemanticSnapshotStats stats,
    TugboatViewportSemanticMap map,
  ) {
    _observeScrollBounds(stats, map.scrollContext);
    for (final node in map.nodes) {
      _observeScrollSemanticNode(stats, node, map.scrollContext);
    }
  }

  void _observeScrollBounds(
    _ScrollSemanticSnapshotStats stats,
    TugboatViewportSemanticScrollContext? scroll,
  ) {
    final top = scroll?.observedTopNorm;
    if (top != null) stats.observedTop = _minimum(stats.observedTop, top);
    final bottom = scroll?.observedBottomNorm;
    if (bottom != null) {
      stats.observedBottom = _maximum(stats.observedBottom, bottom);
    }
  }

  double _minimum(double? current, double next) =>
      current == null || current > next ? next : current;

  double _maximum(double? current, double next) =>
      current == null || current < next ? next : current;

  void _observeScrollSemanticNode(
    _ScrollSemanticSnapshotStats stats,
    TugboatViewportSemanticNode node,
    TugboatViewportSemanticScrollContext? scroll,
  ) {
    if (node.isActionable) stats.actionableCount++;
    final linked = node.linkedFingerprint?.isNotEmpty == true;
    if (linked) stats.linkedCount++;
    stats.nodeKeys.add(_scrollSemanticNodeKey(node, scroll, linked));
  }

  String _scrollSemanticNodeKey(
    TugboatViewportSemanticNode node,
    TugboatViewportSemanticScrollContext? scroll,
    bool linked,
  ) {
    if (linked) return 'fp:${node.linkedFingerprint}';
    final bounds = node.boundsNorm;
    return [
      'node',
      node.source,
      node.role ?? '',
      node.actions.join(','),
      bounds.left.toStringAsFixed(2),
      bounds.top.toStringAsFixed(2),
      bounds.width.toStringAsFixed(2),
      bounds.height.toStringAsFixed(2),
      scroll?.offsetNorm?.toStringAsFixed(2) ?? '',
    ].join('|');
  }

  TugboatViewportSemanticResolution? _resolveTapUnsafe({
    required Offset position,
    required AnchorResolver? resolver,
    required GlobalKey boundaryKey,
    TugboatSceneInventory? inventory,
  }) {
    if (!engineEnabled) return null;
    final rootRender = boundaryKey.currentContext?.findRenderObject();
    if (resolver == null || rootRender is! RenderBox) return null;

    if (inventory != null) {
      maybeEmit(inventory, resolver: resolver);
    }

    final map = _latestMap;
    if (map == null) {
      if (debugLogs) {
        debugPrint(
          '[tugboat] viewport_semantic_tap '
          'point=(${position.dx.toStringAsFixed(1)},${position.dy.toStringAsFixed(1)}) '
          'status=outside_known_ui reason=no_semantic_map',
        );
      }
      return const TugboatViewportSemanticResolution(
        status: 'outside_known_ui',
      );
    }

    return resolver.resolveTapOnViewportSemanticMap(
      tapPosition: position,
      map: map,
      rootRender: rootRender,
      inventory: inventory,
    );
  }
}
