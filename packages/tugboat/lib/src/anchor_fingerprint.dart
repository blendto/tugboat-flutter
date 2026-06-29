part of 'anchors.dart';

/// Algorithm version for canonical-tree fingerprinting (denylist, tokenization).
///
/// v5: retain actionable role widgets (e.g. InkWell) even when on the wrapper
/// denylist, and climb from untokenized hit elements to the nearest tokenized
/// ancestor when building canonical paths.
///
/// v4: visibility and modal-overlay filtering, fresh per-capture trees,
/// generated widget names, and expanded actionable-role detection.
///
/// v3: fixed `[item]` list-collapse (single token per row), generic-aware
/// denylist matching + expanded denylist, and the verbose structural path
/// skeleton moved out of the serialized `*Parts` (hash-only now).
const int tugboatFingerprintSchemaVersion = 5;

const _canonicalDenylist = <String>{
  'Padding',
  'Center',
  'Align',
  'SizedBox',
  'DecoratedBox',
  'MouseRegion',
  'Semantics',
  'DefaultSelectionStyle',
  'RepaintBoundary',
  'Builder',
  'ColoredBox',
  'ConstrainedBox',
  'FractionallySizedBox',
  'LimitedBox',
  'OverflowBox',
  'FittedBox',
  'RotatedBox',
  'Transform',
  'ClipRect',
  'ClipRRect',
  'ClipOval',
  'ClipPath',
  'PhysicalModel',
  'PhysicalShape',
  'Opacity',
  'AnimatedOpacity',
  'FadeTransition',
  'IgnorePointer',
  'AbsorbPointer',
  'NotificationListener',
  'Listener',
  'MergeSemantics',
  'ExcludeSemantics',
  'BlockSemantics',
  'UnconstrainedBox',
  'Baseline',
  'IntrinsicHeight',
  'IntrinsicWidth',
  'Positioned',
  'Flexible',
  'Expanded',
  'Spacer',
  'SafeArea',
  'MediaQuery',
  'AnimatedBuilder',
  'LayoutBuilder',
  'Offstage',
  'FocusScope',
  'Focus',
  'FocusTraversalGroup',
  'HeroControllerScope',
  'UnmanagedRestorationScope',
  'Overlay',
  'TickerMode',
  'RestorationScope',
  'Actions',
  'PrimaryScrollController',
  'ListenableBuilder',
  'PageStorage',
  'Material',
  'AnimatedPhysicalModel',
  'AnimatedDefaultTextStyle',
  'DefaultTextStyle',
  'AnimatedTheme',
  'Theme',
  'CupertinoTheme',
  'InheritedCupertinoTheme',
  'IconTheme',
  'InkWell',
  'CustomMultiChildLayout',
  'LayoutId',
  'KeyedSubtree',
  'ScrollNotificationObserver',
  'CustomPaint',
  'Navigator',
  'DualTransitionBuilder',
  'SnapshotWidget',
  // Scroll/list plumbing: single-child wrappers that sit between a Scrollable
  // and the repeating row. Skipping them lets `[item]` land on the real row.
  'Viewport',
  'ShrinkWrappingViewport',
  'AutomaticKeepAlive',
  'KeepAlive',
  'IndexedSemantics',
  // Pure layout containers: ubiquitous and unstable, add no identity signal.
  'Container',
  'Stack',
  'Row',
  'Column',
  'Flex',
  'Wrap',
  'Flow',
  'IndexedStack',
  'ListBody',
  'Table',
  // Implicit/explicit animations and transitions.
  'SlideTransition',
  'FractionalTranslation',
  'ScaleTransition',
  'SizeTransition',
  'RotationTransition',
  'PositionedTransition',
  'RelativePositionedTransition',
  'AlignTransition',
  'DecoratedBoxTransition',
  'AnimatedSlide',
  'AnimatedContainer',
  'AnimatedPadding',
  'AnimatedAlign',
  'AnimatedPositioned',
  'AnimatedPositionedDirectional',
  'AnimatedSize',
  'AnimatedScale',
  'AnimatedRotation',
  'AnimatedFractionallySizedBox',
  'AnimatedSwitcher',
  'AnimatedCrossFade',
  'AnimatedSlideTransition',
  // State-management providers/builders (generic args stripped before lookup).
  'BlocProvider',
  'BlocBuilder',
  'BlocListener',
  'BlocConsumer',
  'BlocSelector',
  'MultiBlocProvider',
  'MultiBlocListener',
  'RepositoryProvider',
  'MultiRepositoryProvider',
  'Provider',
  'MultiProvider',
  'InheritedProvider',
  'ChangeNotifierProvider',
  'ListenableProvider',
  'ValueListenableProvider',
  'StreamProvider',
  'FutureProvider',
  'ProxyProvider',
  'Consumer',
  'Selector',
  // Async/listenable rebuild wrappers.
  'ValueListenableBuilder',
  'FutureBuilder',
  'StreamBuilder',
  'TweenAnimationBuilder',
  'OrientationBuilder',
  // Navigation/overlay plumbing.
  'PopScope',
  'WillPopScope',
  'Hero',
  'HeroMode',
  'CompositedTransformFollower',
  'CompositedTransformTarget',
  'TapRegion',
  'TextFieldTapRegion',
  'PreferredSize',
  // Visual effect wrappers.
  'BackdropFilter',
  'ShaderMask',
  'ColorFiltered',
  'ImageFiltered',
};

/// Privacy-preserving hash of a label string.
String tugboatLabelHash(String value) {
  if (value.isEmpty) return '';
  return sha256.convert(utf8.encode(value)).toString().substring(0, 16);
}

String tugboatIconHash(IconData icon) =>
    tugboatLabelHash('${icon.codePoint}:${icon.fontFamily ?? ''}');

String tugboatIconLabel(IconData icon) => [
  icon.codePoint,
  if (icon.fontFamily != null && icon.fontFamily!.isNotEmpty) icon.fontFamily,
  if (icon.fontPackage != null && icon.fontPackage!.isNotEmpty)
    icon.fontPackage,
].join(':');
Map<String, int> _summaryFromRoles(List<dynamic>? roles) {
  final summary = <String, int>{};
  if (roles == null) return summary;
  for (final role in roles.cast<String>()) {
    summary[role] = (summary[role] ?? 0) + 1;
  }
  return summary;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _fingerprintForParts(Map<String, String> parts) {
  if (parts.isEmpty) return '';
  final entries = parts.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return tugboatLabelHash(
    entries.map((entry) => '${entry.key}=${entry.value}').join('|'),
  );
}

String _confidenceFloor(Iterable<String> tiers) {
  if (tiers.contains('low')) return 'low';
  if (tiers.contains('medium')) return 'medium';
  return 'high';
}

String _routeKeyConfidence(String routeKey) {
  if (routeKey.startsWith('struct:')) return 'medium';
  return 'high';
}

int _stringMapHash(Map<String, String> map) {
  final entries = map.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return Object.hashAll(entries.map((entry) => '${entry.key}:${entry.value}'));
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
