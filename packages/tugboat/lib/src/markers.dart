import 'package:flutter/widgets.dart';

/// Marks SDK-owned UI so capture skips it.
class TugboatInternal extends StatelessWidget {
  const TugboatInternal({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Marks a subtree to mask under every screenshot privacy policy.
class TugboatSensitive extends StatelessWidget {
  const TugboatSensitive({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Declares a stable developer-owned alias for target matching.
///
/// The tag is transparent to structural target and state identity.
class TugboatTag extends StatelessWidget {
  const TugboatTag(this.id, {required this.child, super.key});

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Tags the active sub-view inside a route (tab, wizard step, etc.).
///
/// When visible on stage, its [label] is included in [TugboatStateAnchor].
class TugboatSubView extends StatelessWidget {
  const TugboatSubView({required this.label, required this.child, super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
