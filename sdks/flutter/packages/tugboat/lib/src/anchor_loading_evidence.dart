part of 'anchors.dart';

/// Runtime type-name fragments that mark a placeholder (skeleton or shimmer)
/// subtree. Matched case-sensitively against the type name without its type
/// arguments, so `Provider<ShimmerController>` is not a placeholder. Flutter's
/// own debug [Placeholder] also matches: it is a placeholder by definition,
/// and it appears in exploration captures only where an app uses it as a stub.
const _placeholderTypeFragments = <String>[
  'Shimmer',
  'Skeleton',
  'Placeholder',
  'Redacted',
];

bool _isPlaceholderWidget(Widget widget) {
  if (widget is TugboatLoading) return true;
  // Scopes carry state for a subtree; they never draw a placeholder.
  if (widget is InheritedWidget) return false;
  final name = widget.runtimeType.toString();
  final generic = name.indexOf('<');
  final base = generic == -1 ? name : name.substring(0, generic);
  return _placeholderTypeFragments.any(base.contains);
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

/// A subtree the progress walk skips: hidden, or with tickers off (a route
/// covered by an opaque route above it, whose spinner neither shows nor
/// turns).
bool _skipsProgressSubtree(Widget widget) =>
    tugboatHidesSubtree(widget) || (widget is TickerMode && !widget.enabled);

typedef _LoadingFlags = ({bool placeholder, bool busy});

const _LoadingFlags _noLoadingFlags = (placeholder: false, busy: false);

/// Loading evidence for one exploration inventory build: a progress-indicator
/// count for the capture tree, plus per-element placeholder and busy flags
/// read from ancestors. Structural only: it never reads text, labels or
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

  /// Flags of every ancestor walked so far, each including its own widget.
  /// Rows of one list share their ancestors, so each chain is walked once.
  final Map<Element, _LoadingFlags> _through = {};

  /// Placeholder and busy flags of [element], from its ancestors up to (not
  /// including) the capture root. Both false when the walk fails.
  _LoadingFlags flagsFor(Element element) {
    if (identical(element, _root)) return _noLoadingFlags;
    final pending = <Element>[];
    var flags = _noLoadingFlags;
    try {
      element.visitAncestorElements((ancestor) {
        if (identical(ancestor, _root)) return false;
        final known = _through[ancestor];
        if (known != null) {
          flags = known;
          return false;
        }
        pending.add(ancestor);
        return true;
      });
    } catch (_) {
      return _noLoadingFlags;
    }
    for (final ancestor in pending.reversed) {
      flags = _withWidget(flags, ancestor.widget);
      _through[ancestor] = flags;
    }
    return flags;
  }

  _LoadingFlags _withWidget(_LoadingFlags above, Widget widget) => (
    placeholder: above.placeholder || _isPlaceholderWidget(widget),
    busy: above.busy || _isBusyBlockerWidget(widget),
  );
}

/// Progress indicators in [root]'s tree, skipping hidden and ticker-disabled
/// subtrees.
int _countProgressIndicators(Element root) {
  var count = 0;
  void walk(Element element) {
    final widget = element.widget;
    if (_skipsProgressSubtree(widget)) return;
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
    busyControls: elements.where((entry) => entry.busy).length,
  );
}
