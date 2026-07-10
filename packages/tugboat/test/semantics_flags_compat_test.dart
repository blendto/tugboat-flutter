import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/semantics_flags_compat.dart';

void main() {
  test('semanticsEnabledFromFlags returns null when enabled state is unknown', () {
    expect(
      semanticsEnabledFromFlags(SemanticsFlags.none),
      isNull,
    );
  });

  test('semanticsEnabledFromFlags reads explicit enabled state', () {
    expect(
      semanticsEnabledFromFlags(
        SemanticsFlags.none.copyWith(
          hasEnabledState: true,
          isEnabled: true,
        ),
      ),
      isTrue,
    );
    expect(
      semanticsEnabledFromFlags(
        SemanticsFlags.none.copyWith(
          hasEnabledState: true,
          isEnabled: false,
        ),
      ),
      isFalse,
    );
  });
}
