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
class TugboatTag extends StatelessWidget {
  const TugboatTag(this.id, {required this.child, super.key});

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
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
  /// Equivalent to `TugboatTag(id, child: this)`.
  Widget tugboatTag(String id) => TugboatTag(id, child: this);

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
