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

/// Reads checked state across Flutter SDK versions.
bool? semanticsCheckedFromFlags(SemanticsFlags flags) {
  final dynamic state = flags;
  final checked = state.isChecked;
  if (checked is bool) {
    if (state.hasCheckedState == true) return checked;
    return null;
  }
  // Flutter 3.36+: CheckedState enum (none / isTrue / isFalse / mixed).
  final name = checked.toString().split('.').last;
  return switch (name) {
    'isTrue' => true,
    'isFalse' => false,
    'none' || 'mixed' => null,
    _ => null,
  };
}

/// Reads toggled state across Flutter SDK versions.
bool? semanticsToggledFromFlags(SemanticsFlags flags) {
  final dynamic state = flags;
  final toggled = state.isToggled;
  if (toggled is bool) return toggled;
  return toggled.toBoolOrNull() as bool?;
}

/// Reads selected state across Flutter SDK versions.
bool? semanticsSelectedFromFlags(SemanticsFlags flags) {
  final dynamic state = flags;
  final selected = state.isSelected;
  if (selected is bool) return selected;
  // Flutter 3.36+: Tristate.
  return selected.toBoolOrNull() as bool?;
}
