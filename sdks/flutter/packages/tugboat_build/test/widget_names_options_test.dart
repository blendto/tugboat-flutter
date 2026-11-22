import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat_build/src/widget_names_options.dart';

void main() {
  group('WidgetNamesOptions.fromConfig', () {
    test('defaults to tugboatWidgetNames and no exclusions', () {
      final options = WidgetNamesOptions.fromConfig(const {});

      expect(options.variableName, 'tugboatWidgetNames');
      expect(options.exclude, isEmpty);
    });

    test('reads variable_name and exclude', () {
      final options = WidgetNamesOptions.fromConfig(const {
        'variable_name': 'appWidgetNames',
        'exclude': ['lib/web/**', 'lib/gen/**'],
      });

      expect(options.variableName, 'appWidgetNames');
      expect(options.exclude, ['lib/web/**', 'lib/gen/**']);
    });

    test('rejects an unknown key so a typo is not silently ignored', () {
      expect(
        () => WidgetNamesOptions.fromConfig(const {'excludes': <String>[]}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a variable name that is not an identifier', () {
      expect(
        () => WidgetNamesOptions.fromConfig(const {'variable_name': 'a b'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects reserved words, private names and import prefixes', () {
      const cases = {
        'class': 'reserved word',
        'null': 'reserved word',
        '_names': 'must be public',
        '_': 'must be public',
        '_i0': 'import prefixes',
        '_i12': 'import prefixes',
      };
      for (final entry in cases.entries) {
        expect(
          () => WidgetNamesOptions.fromConfig({'variable_name': entry.key}),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains(entry.value),
            ),
          ),
          reason: entry.key,
        );
      }
    });

    test('rejects a variable name that is not a string', () {
      expect(
        () => WidgetNamesOptions.fromConfig(const {'variable_name': 3}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts public names that merely look similar', () {
      for (final name in ['i0', 'iNames', 'classes', 'names_', 'Names']) {
        expect(
          WidgetNamesOptions.fromConfig({'variable_name': name}).variableName,
          name,
        );
      }
    });

    test('rejects an exclude that is not a list of strings', () {
      expect(
        () => WidgetNamesOptions.fromConfig(const {'exclude': 'lib/web/**'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
