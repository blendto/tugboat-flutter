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

/// Marks a subtree that shows a loading or placeholder state (a custom skeleton,
/// shimmer or spinner) so exploration inventories can report it.
///
/// Transparent: it adds no canonical path segment and changes no fingerprint,
/// route key or inventory hash. Use it when the skeleton's widget type name
/// does not contain a recognised fragment (`Shimmer`, `Skeleton`,
/// `Placeholder`, `Redacted`).
///
/// [enabled] switches the marker on and off, for skeleton widgets that stay
/// mounted after loading, such as
/// `Skeletonizer(enabled: loading, child: TugboatLoading(enabled: loading,
/// child: content))`. Walking up from an element, the nearest `TugboatLoading`
/// decides: enabled marks the element as a placeholder, disabled does not, and
/// the walk stops there. Only when no `TugboatLoading` is above an element
/// does the type-name match on its ancestors apply. A disabled marker
/// therefore also switches off name-matched detection for its subtree. The
/// marker is transparent in both states, and toggling [enabled] changes no
/// fingerprint.
class TugboatLoading extends StatelessWidget {
  const TugboatLoading({this.enabled = true, required this.child, super.key});

  /// Whether the subtree is a loading placeholder. Defaults to true.
  final bool enabled;

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
