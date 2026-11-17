part of 'anchors.dart';

/// Elements walked at most in one excluded subtree while looking for the
/// control it hides; a larger subtree is not reported.
const _excludedSemanticsWalkLimit = 400;

/// Single-child levels followed at most from an excluded root down to the
/// control a hit lands on.
const _hiddenChainLimit = 24;

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
    final paths = [
      for (final entry in listed) entry.canonicalPath,
      for (final entries in byFingerprint.values)
        for (final entry in entries) entry.canonicalPath,
    ];
    byFingerprint.forEach((fingerprint, entries) {
      if (entries.length != 1 || taken.contains(fingerprint)) return;
      final prefix = '${entries.single.canonicalPath}/';
      if (paths.any((path) => path.startsWith(prefix))) return;
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
    if (target == null || !_hasIdentity(target)) return null;
    return TugboatSceneInventoryEntry(
      fingerprint: target.fingerprint!,
      canonicalPath: target.canonicalPath!,
      widgetType: _widgetName(control.widget),
      role: role.name,
      actions: [...role.actions]..sort(),
      enabled: role.enabled,
      boundsNorm: TugboatNormalizedBounds.fromRect(rect, rootRender.size),
      tier: 'interactive',
      visibleFraction: evidence.visibleFractionFor(control, rect),
    );
  }

  static bool _hasIdentity(TugboatTargetAnchor target) =>
      (target.fingerprint?.isNotEmpty ?? false) &&
      (target.canonicalPath?.isNotEmpty ?? false);

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
  /// none, more than one, or more elements than the walk limit. A scrollable
  /// is not the control: the walk goes on into it, so a hidden list of
  /// buttons counts its buttons.
  Element? _soleHiddenControl(Element root) {
    final found = <Element>[];
    final pending = <Element>[root];
    var walked = 0;
    while (pending.isNotEmpty) {
      if (++walked > _excludedSemanticsWalkLimit || found.length > 1) {
        return null;
      }
      final element = pending.removeLast();
      if (_isHiddenControl(element.widget)) {
        found.add(element);
        continue;
      }
      element.visitChildElements(pending.add);
    }
    return found.length == 1 ? found.single : null;
  }

  bool _isHiddenControl(Widget widget) {
    final role = tugboatRoleForWidget(widget);
    return role != null && role.name != 'scrollable';
  }

  /// What a tap at the centre of [control] resolves to, when that tap reaches
  /// the control and names it: the control itself names the hit
  /// ([_hiddenControlNaming]), or the hit resolves to a path with no role
  /// (the widget above the skipped subtree). Null otherwise.
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
    final resolved = _resolveHitPath(
      AnchorResolver._hitTargets(result),
      route: route,
      tokenMap: tokenMap,
      rootRender: rootRender,
    );
    final target = resolved.anchor;
    if (target == null) return null;
    if (identical(resolved.hiddenControl, control)) return target;
    return target.role != null ? null : target;
  }

  /// The control a hit inside an excluded-semantics subtree lands on, found
  /// from the hit path alone: the subtree root is the first
  /// `RenderExcludeSemantics` on the path, one the token map recorded, and
  /// the control is the first role on a chain of single children below it
  /// (`ExcludeSemantics` > `ElevatedButton`), when the hit reaches it. A root
  /// with a fork above its first control (two hidden buttons, a hidden list)
  /// gives null, so no two controls share the identity. No subtree walk:
  /// only the chain, at most [_hiddenChainLimit] levels.
  Element? _hiddenControlOnHitPath(
    List<HitTestTarget> hitPath,
    _TokenMap tokenMap,
  ) {
    if (tokenMap.excludedSemantics.isEmpty) return null;
    for (final target in hitPath) {
      if (target is RenderExcludeSemantics && target.excluding) {
        return _hiddenChainControl(target, hitPath, tokenMap);
      }
      // A retained element first: the hit is not inside a skipped subtree.
      if (target is RenderObject &&
          tokenMap.renderElements.containsKey(target)) {
        return null;
      }
    }
    return null;
  }

  Element? _hiddenChainControl(
    RenderExcludeSemantics render,
    List<HitTestTarget> hitPath,
    _TokenMap tokenMap,
  ) {
    Element? root;
    for (final excluded in tokenMap.excludedSemantics) {
      if (identical(excluded.renderObject, render)) root = excluded;
    }
    if (root == null || !_parentIsIncluded(root, tokenMap)) return null;
    var current = root;
    for (var level = 0; level < _hiddenChainLimit; level++) {
      final child = _onlyChild(current);
      if (child == null) return null;
      final role = tugboatRoleForWidget(child.widget);
      if (role != null) {
        if (role.name == 'scrollable') return null;
        return hitPath.contains(child.renderObject) ? child : null;
      }
      current = child;
    }
    return null;
  }

  static Element? _onlyChild(Element element) {
    Element? only;
    var count = 0;
    element.visitChildElements((child) {
      only = child;
      count++;
    });
    return count == 1 ? only : null;
  }

  /// [hidden] names a hit whose first retained element is [element] when no
  /// control other than a scrollable encloses it: then the tap is the hidden
  /// control (role, actions, box) at [element]'s path, the path a tap on it
  /// has always had when nothing encloses it. A hidden control inside a
  /// scrollable (Blend's onboarding Continue in a `PageView`) no longer
  /// takes the scrollable's identity. Inside another control (an `InkWell`
  /// around the wrapper) that control stays the identity, as before.
  Element? _hiddenControlNaming(
    Element? hidden,
    Element element,
    _TokenMap tokenMap,
  ) {
    if (hidden == null) return null;
    final enclosing = _identityElementFor(element, tokenMap);
    if (enclosing == null) return hidden;
    final role = tugboatRoleForWidget(enclosing.widget);
    return role?.name == 'scrollable' ? hidden : null;
  }
}
