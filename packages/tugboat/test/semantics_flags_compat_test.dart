import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/semantics_flags_compat.dart';

void main() {
  test(
    'semanticsEnabledFromFlags returns null when enabled state is unknown',
    () {
      expect(semanticsEnabledFromFlags(SemanticsFlags.none), isNull);
    },
  );

  test('semanticsEnabledFromFlags reads explicit enabled state', () {
    expect(semanticsEnabledFromFlags(_flagsWithEnabled(true)), isTrue);
    expect(semanticsEnabledFromFlags(_flagsWithEnabled(false)), isFalse);
  });
}

/// Builds enabled-state flags across Flutter 3.35 bool pairs and 3.36+ Tristate.
SemanticsFlags _flagsWithEnabled(bool enabled) {
  final dynamic none = SemanticsFlags.none;
  try {
    final dynamic tristate = enabled
        ? (Tristate.isTrue as dynamic)
        : (Tristate.isFalse as dynamic);
    return none.copyWith(isEnabled: tristate) as SemanticsFlags;
  } catch (_) {
    return none.copyWith(hasEnabledState: true, isEnabled: enabled)
        as SemanticsFlags;
  }
}
