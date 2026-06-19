import 'package:flutter/widgets.dart';

/// Marks SDK-owned UI so capture skips it.
class PmkitInternal extends StatelessWidget {
  const PmkitInternal({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Marks a subtree to mask under every screenshot privacy policy.
class PmkitSensitive extends StatelessWidget {
  const PmkitSensitive({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Declares a stable developer-owned alias for target matching.
///
/// The tag is transparent to structural target and state identity.
class PmkitTag extends StatelessWidget {
  const PmkitTag(this.id, {required this.child, super.key});

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Tags the active sub-view inside a route (tab, wizard step, etc.).
///
/// When visible on stage, its [label] is included in [PmkitStateAnchor].
class PmkitSubView extends StatelessWidget {
  const PmkitSubView({required this.label, required this.child, super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
