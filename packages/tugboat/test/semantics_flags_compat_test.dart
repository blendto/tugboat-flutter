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
    for (final value in <bool>[true, false]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Semantics(
            enabled: value,
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final flags = tester
          .getSemantics(find.byType(Semantics))
          .getSemanticsData()
          .flagsCollection;
      expect(semanticsEnabledFromFlags(flags), value);
    }
  });

  testWidgets('semanticsCheckedFromFlags reads true, false, and none', (
    tester,
  ) async {
    for (final value in <bool?>[true, false, null]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Semantics(
            checked: value,
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final flags = tester
          .getSemantics(find.byType(Semantics))
          .getSemanticsData()
          .flagsCollection;
      expect(semanticsCheckedFromFlags(flags), value);
    }
  });

  testWidgets('semanticsCheckedFromFlags treats mixed as unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Checkbox(tristate: true, value: null, onChanged: (_) {}),
        ),
      ),
    );
    final flags = tester
        .getSemantics(find.byType(Checkbox))
        .getSemanticsData()
        .flagsCollection;
    final dynamic runtimeFlags = flags;
    expect(
      semanticsCheckedFromFlags(flags),
      runtimeFlags.isChecked is bool ? isFalse : isNull,
    );
  });
}
