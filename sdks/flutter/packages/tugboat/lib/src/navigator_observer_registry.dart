import 'package:flutter/rendering.dart';
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
      final navigator = source.observedNavigator;
      if (navigator == null) continue;
      fallback = source;
      if (_navigatorIsOnScreen(navigator)) return source;
    }
    return fallback;
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

  static bool _navigatorIsOnScreen(NavigatorState navigator) {
    final context = navigator.context;
    if (!_ancestorsAllowPainting(context)) return false;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return false;
    if (!renderObject.attached || !renderObject.hasSize) return false;
    final size = renderObject.size;
    if (size.width <= 0 || size.height <= 0) return false;
    final rect = renderObject.localToGlobal(Offset.zero) & size;
    final view = View.of(context);
    final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    if (!rect.overlaps(screen)) return false;
    return _hitTestIncludesRenderObject(rect.center, context, renderObject);
  }

  static bool _hitTestIncludesRenderObject(
    Offset globalPosition,
    BuildContext context,
    RenderObject target,
  ) {
    final result = BoxHitTestResult();
    final viewId = View.of(context).viewId;
    WidgetsBinding.instance.hitTestInView(result, globalPosition, viewId);
    if (result.path.isEmpty) return false;
    for (final entry in result.path) {
      final hit = entry.target;
      if (hit is! RenderObject) continue;
      RenderObject? node = hit;
      while (node != null) {
        if (identical(node, target)) return true;
        node = node.parent;
      }
    }
    return false;
  }

  static bool _ancestorsAllowPainting(BuildContext context) {
    if (context is! Element) return true;
    var blocked = false;
    context.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Offstage && widget.offstage) {
        blocked = true;
        return false;
      }
      if (widget is Visibility && !widget.visible) {
        blocked = true;
        return false;
      }
      if (widget is TickerMode && !widget.enabled) {
        blocked = true;
        return false;
      }
      return true;
    });
    return !blocked;
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
