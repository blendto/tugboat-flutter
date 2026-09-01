import 'dart:ui';

/// Reads [SemanticsFlags.isEnabled] across Flutter SDK versions.
///
/// Flutter 3.35 and earlier expose paired `hasEnabledState` + `isEnabled`
/// booleans on [SemanticsFlags]. Flutter 3.36+ replaces that pair with a
/// single [Tristate] `isEnabled` value (`none` means unknown).
bool? semanticsEnabledFromFlags(SemanticsFlags flags) {
  final dynamic state = flags;
  final enabled = state.isEnabled;
  if (enabled is bool) {
    if (state.hasEnabledState == true) return enabled;
    return null;
  }
  return enabled.toBoolOrNull() as bool?;
}
