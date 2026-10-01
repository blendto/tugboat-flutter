import 'package:flutter/widgets.dart';

/// Sources for [NavigatorState] registered by [TugboatNavigatorObserver].
abstract interface class TugboatObservedNavigatorSource {
  NavigatorState? get observedNavigator;
}

/// Tracks installed Tugboat navigator observers for session route seeding.
final class TugboatNavigatorObserverRegistry {
  TugboatNavigatorObserverRegistry._();

  static final Set<TugboatObservedNavigatorSource> _sources =
      <TugboatObservedNavigatorSource>{};

  static void register(TugboatObservedNavigatorSource source) {
    _sources.add(source);
  }

  static void unregister(TugboatObservedNavigatorSource source) {
    _sources.remove(source);
  }

  /// Deepest observed navigator (nested observers win over their ancestors).
  static NavigatorState? deepestObservedNavigator() {
    final states = _sources
        .map((source) => source.observedNavigator)
        .whereType<NavigatorState>()
        .toList(growable: false);
    if (states.isEmpty) return null;
    NavigatorState? deepest;
    for (final candidate in states) {
      final hasChild = states.any(
        (other) =>
            !identical(other, candidate) &&
            _isDescendantNavigator(other, candidate),
      );
      if (!hasChild) deepest = candidate;
    }
    return deepest ?? states.first;
  }

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
