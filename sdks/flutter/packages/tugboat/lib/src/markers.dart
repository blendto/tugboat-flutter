import 'package:flutter/widgets.dart';

/// Marks SDK-owned UI so capture skips it.
class TugboatInternal extends StatelessWidget {
  const TugboatInternal({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Marks a subtree that must always be masked in screenshots.
class TugboatSensitive extends StatelessWidget {
  const TugboatSensitive({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Declares a stable developer-owned alias for target matching.
///
/// Transparent to structural target and state identity; useful when runtime
/// type names are obfuscated or when a control needs a durable id.
///
/// When [accessibility] is true, [id] is also published as the platform
/// accessibility identifier through a [Semantics] node (Android resource-id,
/// iOS `accessibilityIdentifier`). It defaults to false (opt-in).
///
/// Enable it on a single control, not on a container: the identifier goes on
/// a node above the control's subtree, so on a container it does not identify
/// the individual controls inside. On Material buttons (ElevatedButton,
/// TextButton, FilledButton, OutlinedButton, IconButton) the identifier lands
/// on a label-less parent node above the labelled button, so it is not on the
/// button node itself. See the semantics gate in the SDK tests for measured
/// results per control.
class TugboatTag extends StatelessWidget {
  const TugboatTag(
    this.id, {
    required this.child,
    this.accessibility = false,
    super.key,
  });

  final String id;
  final Widget child;

  /// Whether [id] is exposed as the platform accessibility identifier.
  final bool accessibility;

  @override
  Widget build(BuildContext context) =>
      accessibility ? Semantics(identifier: id, child: child) : child;
}

/// Tags the active sub-view inside a route (tab, wizard step, etc.).
///
/// When visible on stage, its [label] is included in state signatures and
/// scroll attribution.
class TugboatSubView extends StatelessWidget {
  const TugboatSubView({required this.label, required this.child, super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Modifier-style spelling of the developer markers above.
///
/// Each method wraps the receiver in the matching marker widget, so
/// `widget.tugboatTag('id')` is identical to `TugboatTag('id', child: widget)`.
/// Use it to add a marker as a one-line suffix instead of re-indenting the
/// control:
///
/// ```dart
/// ElevatedButton(onPressed: pay, child: Text('Pay')).tugboatTag('checkout'),
/// ```
extension TugboatMarkers on Widget {
  /// Declares a stable developer-owned alias for target matching.
  ///
  /// Equivalent to `TugboatTag(id, child: this, accessibility: accessibility)`.
  /// Pass `accessibility: true` to also publish [id] as the platform
  /// accessibility identifier on this control (off by default; see
  /// [TugboatTag] for limits on buttons and containers).
  Widget tugboatTag(String id, {bool accessibility = false}) =>
      TugboatTag(id, accessibility: accessibility, child: this);

  /// Marks this subtree as always masked in screenshots.
  ///
  /// Equivalent to `TugboatSensitive(child: this)`.
  Widget tugboatSensitive() => TugboatSensitive(child: this);

  /// Tags this subtree as the active sub-view with [label].
  ///
  /// Equivalent to `TugboatSubView(label: label, child: this)`.
  Widget tugboatSubView(String label) =>
      TugboatSubView(label: label, child: this);
}
