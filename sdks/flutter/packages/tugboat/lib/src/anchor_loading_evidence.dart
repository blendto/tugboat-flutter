part of 'anchors.dart';

/// Runtime type-name fragments that mark a placeholder (skeleton or shimmer)
/// subtree. Matched case-sensitively. Flutter's own debug [Placeholder] also
/// matches: it is a placeholder by definition, and it appears in exploration
/// captures only where an app uses it as a stub.
const _placeholderTypeFragments = <String>[
  'Shimmer',
  'Skeleton',
  'Placeholder',
  'Redacted',
];

bool _isPlaceholderWidget(Widget widget) {
  if (widget is TugboatLoading) return true;
  final name = widget.runtimeType.toString();
  return _placeholderTypeFragments.any(name.contains);
}

/// Every [ProgressIndicator] (Circular, Linear, Refresh) and the Cupertino
/// activity indicator. `RefreshProgressIndicator` is a
/// `CircularProgressIndicator`, so one `is` check counts it once.
bool _isProgressIndicatorWidget(Widget widget) =>
    widget is ProgressIndicator || widget is CupertinoActivityIndicator;

/// A pointer blocker that stops taps from reaching the controls beneath it.
bool _isBusyBlockerWidget(Widget widget) =>
    (widget is AbsorbPointer && widget.absorbing) ||
    (widget is IgnorePointer && widget.ignoring);

/// Loading evidence for one exploration inventory build: a progress-indicator
/// count for the whole capture tree, plus per-element placeholder and busy
/// flags read from ancestors. Structural only: it never reads text, labels or
/// pixels. Only built when the inventory is emitted, never on the production
/// tap path.
class _LoadingEvidence {
  _LoadingEvidence._(this._root, this.progressIndicators);

  /// Null when there is no capture root to walk.
  static _LoadingEvidence? capture(BuildContext? context) {
    if (context is! Element) return null;
    final root = context;
    try {
      return _LoadingEvidence._(root, _countProgressIndicators(root));
    } catch (_) {
      // A racing tree only costs the optional field: no counts at all.
      return null;
    }
  }

  final Element _root;
  final int progressIndicators;
  final Set<String> _busyFingerprints = <String>{};

  /// Distinct interactive entries that sit beneath a busy blocker.
  int get busyControls => _busyFingerprints.length;

  void noteBusy(String fingerprint) => _busyFingerprints.add(fingerprint);

  /// Placeholder and busy flags of [element], from its ancestors up to (not
  /// including) the capture root. Both false when the walk fails.
  ({bool placeholder, bool busy}) flagsFor(Element element) {
    var placeholder = false;
    var busy = false;
    if (identical(element, _root)) return (placeholder: false, busy: false);
    try {
      element.visitAncestorElements((ancestor) {
        if (identical(ancestor, _root)) return false;
        final widget = ancestor.widget;
        placeholder = placeholder || _isPlaceholderWidget(widget);
        busy = busy || _isBusyBlockerWidget(widget);
        return !(placeholder && busy);
      });
    } catch (_) {
      return (placeholder: false, busy: false);
    }
    return (placeholder: placeholder, busy: busy);
  }
}

/// Progress indicators in [root]'s tree, skipping hidden subtrees.
int _countProgressIndicators(Element root) {
  var count = 0;
  void walk(Element element) {
    final widget = element.widget;
    if (tugboatHidesSubtree(widget)) return;
    if (_isProgressIndicatorWidget(widget)) count++;
    element.visitChildElements(walk);
  }

  root.visitChildElements(walk);
  return count;
}

/// The `loading` summary for an inventory with [elements], from [evidence].
TugboatInventoryLoading? _loadingSummary(
  _LoadingEvidence? evidence,
  List<TugboatSceneInventoryEntry> elements,
) {
  if (evidence == null) return null;
  return TugboatInventoryLoading(
    progressIndicators: evidence.progressIndicators,
    placeholders: elements.where((entry) => entry.placeholder).length,
    busyControls: evidence.busyControls,
  );
}
