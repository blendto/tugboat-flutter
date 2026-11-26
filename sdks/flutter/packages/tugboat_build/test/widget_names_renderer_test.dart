import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat_build/src/widget_names_renderer.dart';
import 'package:tugboat_build/src/widget_scan.dart';

import 'support/fixture_project.dart';

const WidgetClass _home = WidgetClass(
  libraryUri: 'package:app/home.dart',
  name: 'HomeScreen',
);
const WidgetClass _card = WidgetClass(
  libraryUri: 'package:app/src/card.dart',
  name: 'CartCard',
);
const WidgetClass _otherCard = WidgetClass(
  libraryUri: 'package:app/src/other_card.dart',
  name: 'CartCard',
);

String _render(Iterable<WidgetClass> named, {String name = 'names'}) =>
    renderWidgetNames(variableName: name, named: named);

void main() {
  group('renderWidgetNames', () {
    test('is independent of input order and duplicates', () {
      final forward = _render([_home, _card, _otherCard]);

      expect(_render([_otherCard, _home, _card, _home]), forward);
      expect(_render([_card, _otherCard, _home].reversed), forward);
    });

    test('sorts entries by name, then by library', () {
      final source = _render([_home, _otherCard, _card]);

      final keys = RegExp(
        r'^\s+(_i\d+\.\w+):',
        multiLine: true,
      ).allMatches(source).map((m) => m.group(1)).toList();
      // Libraries sort by URI: home (_i0), card (_i1), other_card (_i2).
      expect(keys, ['_i1.CartCard', '_i2.CartCard', '_i0.HomeScreen']);
    });

    test('imports each library once under a stable prefix', () {
      const second = WidgetClass(
        libraryUri: 'package:app/home.dart',
        name: 'HomeHeader',
      );
      final source = _render([_home, second, _card]);

      expect("import 'package:app/home.dart'".allMatches(source), hasLength(1));
      expect(source, contains("import 'package:app/home.dart' as _i0;"));
      expect(source, contains("import 'package:app/src/card.dart' as _i1;"));
      expect(source, contains("  _i0.HomeScreen: 'HomeScreen',"));
      expect(source, contains("  _i0.HomeHeader: 'HomeHeader',"));
    });

    test('escapes dollar signs in class names', () {
      const dollar = WidgetClass(
        libraryUri: 'package:app/a.dart',
        name: r'Row$Item',
      );

      expect(_render([dollar]), contains(r"_i0.Row$Item: 'Row\$Item',"));
    });

    test('renders an empty map for a package without widgets', () {
      final source = _render(const []);

      expect(source, isNot(contains('import ')));
      expect(source, contains('const Map<Type, String> names = {\n};'));
    });

    test('records skipped widgets in a comment, not in the map', () {
      final source = renderWidgetNames(
        variableName: 'names',
        named: [_home],
        generic: const [
          WidgetClass(libraryUri: 'package:app/p.dart', name: 'Picker'),
        ],
        privateCount: 3,
      );

      expect(source, contains('// - 3 private (leading underscore)'));
      expect(source, contains('// - Picker (generic), package:app/p.dart'));
      expect(source, isNot(contains('Picker:')));
    });

    test('generated source analyzes without errors', () async {
      final project = await FixtureProject.create({
        'lib/home.dart': '''
import 'package:flutter/widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen();
}

class Row\$Item extends StatelessWidget {
  const Row\$Item();
}
''',
        'lib/src/card.dart': '''
import 'package:flutter/widgets.dart';

class CartCard extends StatelessWidget {
  const CartCard();
}
''',
        'lib/src/other_card.dart': '''
import 'package:flutter/widgets.dart';

class CartCard extends StatelessWidget {
  const CartCard();
}
''',
        'lib/tugboat_widget_names.g.dart': renderWidgetNames(
          variableName: 'tugboatWidgetNames',
          named: const [
            _home,
            _card,
            _otherCard,
            WidgetClass(libraryUri: 'package:app/home.dart', name: r'Row$Item'),
          ],
        ),
        // A const context proves the map is a valid compile-time constant:
        // duplicate keys or non-type keys are errors here.
        'lib/use.dart': '''
import 'tugboat_widget_names.g.dart';

const Map<Type, String> exported = tugboatWidgetNames;
''',
      });
      addTearDown(project.dispose);

      expect(await project.errors('tugboat_widget_names.g.dart'), isEmpty);
      expect(await project.errors('use.dart'), isEmpty);
    });
  });
}
