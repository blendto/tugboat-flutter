import 'package:flutter/widgets.dart';

/// Sources for [NavigatorState] registered by [TugboatNavigatorObserver].
abstract interface class TugboatObservedNavigatorSource {
  NavigatorState? get observedNavigator;

  /// Bottom → top routes observed while capture was dormant or active.
  List<Route<dynamic>> get retainedRouteStack;

  bool get hasRetainedRoutes;
}

/// Tracks installed Tugboat navigator observers for session route seeding.
final class TugboatNavigatorObserverRegistry {
  TugboatNavigatorObserverRegistry._();

  static final List<WeakReference<TugboatObservedNavigatorSource>> _sources =
      <WeakReference<TugboatObservedNavigatorSource>>[];

  static void register(TugboatObservedNavigatorSource source) {
    _prune();
    _sources.add(WeakReference<TugboatObservedNavigatorSource>(source));
  }

  /// Drops detached observers; keeps [retainRoot] (the process root observer).
  static void resetForTest({TugboatObservedNavigatorSource? retainRoot}) {
    _prune();
    _sources.removeWhere((reference) {
      final source = reference.target;
      return source != null && !identical(source, retainRoot);
    });
  }

  static void _prune() {
    _sources.removeWhere((reference) => reference.target == null);
  }

  /// Observer whose retained stack should seed the next session.
  static TugboatObservedNavigatorSource? seedSource() {
    _prune();
    final leaves = _leafSources();
    TugboatObservedNavigatorSource? fallback;
    for (final source in leaves) {
      if (!source.hasRetainedRoutes) continue;
      fallback = source;
      final stack = source.retainedRouteStack;
      if (stack.isEmpty) continue;
      if (_routeIsPainting(stack.last)) return source;
    }
    if (fallback != null) return fallback;
    for (final source in leaves) {
      if (source.hasRetainedRoutes) return source;
    }
    return null;
  }

  static List<TugboatObservedNavigatorSource> _leafSources() {
    final sources = _sources
        .map((reference) => reference.target)
        .whereType<TugboatObservedNavigatorSource>()
        .toList(growable: false);
    final navigators = sources
        .map((source) => source.observedNavigator)
        .whereType<NavigatorState>()
        .toList(growable: false);
    return sources
        .where((source) {
          final navigator = source.observedNavigator;
          if (navigator == null) return false;
          final hasChild = navigators.any(
            (other) =>
                !identical(other, navigator) &&
                _isDescendantNavigator(other, navigator),
          );
          return !hasChild;
        })
        .toList(growable: false);
  }

  static bool _routeIsPainting(Route<dynamic> route) =>
      route.isActive && route.isCurrent;

  static bool _isDescendantNavigator(
    NavigatorState descendant,
    NavigatorState ancestor,
  ) {
    var isUnder = false;
    descendant.context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is NavigatorState) {
        if (identical(element.state, ancestor)) {
          isUnder = true;
          return false;
        }
        if (identical(element.state, descendant)) {
          return true;
        }
      }
      return true;
    });
    return isUnder;
  }
}
