part of 'anchors.dart';

/// Elements walked at most in one excluded subtree while looking for the
/// control it hides; a larger subtree is not reported.
const _excludedSemanticsWalkLimit = 400;

/// Controls an app builds under `ExcludeSemantics` to give them one semantics
/// node of its own (`Semantics(label: ..., child: ExcludeSemantics(child:
/// ElevatedButton(...)))`). The token map skips such a subtree, so a tap on
/// the control resolves, in both modes, to the nearest retained widget above
/// it with no role (the pressed-path fallback of 0.10.10). Exploration
/// inventories list that identity as the control's entry, so the tap joins
/// an inventory and the control is seen before anyone taps it.
extension TugboatExcludedSemanticsApi on AnchorResolver {
  /// Adds one entry per hidden control that a tap at its centre would
  /// resolve to, exploration only. Fails closed: a subtree hiding no control
  /// or more than one, a control a tap at its centre does not reach (it
  /// ignores pointers or is covered), a resolved target with a role (some
  /// other control is the identity), a fingerprint two hidden controls or
  /// an existing entry claim, and a path that other entries sit under (a
  /// page or section, not the control) are all left out.
  void _addExcludedSemanticsControls({
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required String? route,
    required _BoundsEvidence evidence,
    required Map<String, TugboatSceneInventoryEntry> interactiveByFingerprint,
    required List<TugboatSceneInventoryEntry> contentEntries,
  }) {
    final byFingerprint = <String, List<TugboatSceneInventoryEntry>>{};
    for (final excluded in tokenMap.excludedSemantics) {
      final entry = _excludedSemanticsEntry(
        excluded,
        tokenMap: tokenMap,
        rootRender: rootRender,
        route: route,
        evidence: evidence,
      );
      if (entry == null) continue;
      (byFingerprint[entry.fingerprint] ??= []).add(entry);
    }
    final listed = [...interactiveByFingerprint.values, ...contentEntries];
    final taken = {
      for (final entry in listed) ...[entry.fingerprint, ...entry.aliases],
    };
    byFingerprint.forEach((fingerprint, entries) {
      if (entries.length != 1 || taken.contains(fingerprint)) return;
      final prefix = '${entries.single.canonicalPath}/';
      if (listed.any((entry) => entry.canonicalPath.startsWith(prefix))) return;
      interactiveByFingerprint[fingerprint] = entries.single;
    });
  }

  TugboatSceneInventoryEntry? _excludedSemanticsEntry(
    Element excluded, {
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required String? route,
    required _BoundsEvidence evidence,
  }) {
    if (!_parentIsIncluded(excluded, tokenMap)) return null;
    final control = _soleHiddenControl(excluded);
    if (control == null) return null;
    final role = tugboatRoleForWidget(control.widget);
    final rect = _paintRectInRoot(control, rootRender);
    if (role == null || rect == null || rect.isEmpty) return null;
    final target = _hiddenControlTarget(
      control,
      rect.center,
      tokenMap: tokenMap,
      rootRender: rootRender,
      route: route,
    );
    final fingerprint = target?.fingerprint ?? '';
    final path = target?.canonicalPath ?? '';
    if (fingerprint.isEmpty || path.isEmpty) return null;
    return TugboatSceneInventoryEntry(
      fingerprint: fingerprint,
      canonicalPath: path,
      widgetType: _widgetName(control.widget),
      role: role.name,
      actions: [...role.actions]..sort(),
      enabled: role.enabled,
      boundsNorm: TugboatNormalizedBounds.fromRect(rect, rootRender.size),
      tier: 'interactive',
      visibleFraction: evidence.visibleFractionFor(control, rect),
    );
  }

  /// Whether [excluded] sits in the visible tree (not under a route a modal
  /// barrier hides).
  bool _parentIsIncluded(Element excluded, _TokenMap tokenMap) {
    Element? parent;
    excluded.visitAncestorElements((ancestor) {
      parent = ancestor;
      return false;
    });
    return parent != null && tokenMap.includedElements.contains(parent);
  }

  /// The one outermost control in [root]'s subtree, or null when it holds
  /// none, more than one, or more elements than the walk limit.
  Element? _soleHiddenControl(Element root) {
    final found = <Element>[];
    final pending = <Element>[root];
    var walked = 0;
    while (pending.isNotEmpty) {
      if (++walked > _excludedSemanticsWalkLimit || found.length > 1) {
        return null;
      }
      final element = pending.removeLast();
      if (tugboatRoleForWidget(element.widget) != null) {
        found.add(element);
        continue;
      }
      element.visitChildElements(pending.add);
    }
    return found.length == 1 ? found.single : null;
  }

  /// What a tap at the centre of [control] resolves to, when that tap reaches
  /// the control and resolves to a path with no role (the widget above the
  /// skipped subtree). Null otherwise.
  TugboatTargetAnchor? _hiddenControlTarget(
    Element control,
    Offset center, {
    required _TokenMap tokenMap,
    required RenderBox rootRender,
    required String? route,
  }) {
    final controlRender = control.renderObject;
    final result = BoxHitTestResult();
    rootRender.hitTest(result, position: center);
    final hitsControl = result.path.any(
      (entry) => identical(entry.target, controlRender),
    );
    if (!hitsControl) return null;
    final target = _targetFromHitPath(
      AnchorResolver._hitTargets(result),
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
    );
    return target == null || target.role != null ? null : target;
  }
}
