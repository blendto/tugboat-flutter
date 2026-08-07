import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/semantics_flags_compat.dart';

void main() {
  test(
    'semanticsEnabledFromFlags returns null when enabled state is unknown',
    () {
      expect(semanticsEnabledFromFlags(SemanticsFlags.none), isNull);
    },
  );

  testWidgets('semanticsEnabledFromFlags reads explicit enabled state', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        Semantics(container: true, enabled: true, child: SizedBox.shrink()),
      );
      final enabledFlags = tester
          .getSemantics(find.byType(Semantics))
          .getSemanticsData()
          .flagsCollection;
      expect(semanticsEnabledFromFlags(enabledFlags), isTrue);

      await tester.pumpWidget(
        Semantics(container: true, enabled: false, child: SizedBox.shrink()),
      );
      final disabledFlags = tester
          .getSemantics(find.byType(Semantics))
          .getSemanticsData()
          .flagsCollection;
      expect(semanticsEnabledFromFlags(disabledFlags), isFalse);
    } finally {
      semanticsHandle.dispose();
    }
  });
}
