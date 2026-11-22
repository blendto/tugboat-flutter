import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat_build/src/widget_scan.dart';

import 'support/fixture_project.dart';

const String _appUri = 'package:app';

Future<LibraryScan> _scan(String source, {Map<String, String>? others}) async {
  final project = await FixtureProject.create({
    'lib/a.dart': source,
  }, otherPackages: others ?? const {});
  addTearDown(project.dispose);
  return scanLibrary(await project.library('a.dart'));
}

List<String> _names(List<WidgetClass> widgets) =>
    widgets.map((w) => w.name).toList()..sort();

void main() {
  group('scanLibrary', () {
    test('fails loudly on an object without the analyzer members it reads', () {
      expect(
        () => scanLibrary(Object()),
        throwsA(
          isA<UnsupportedAnalyzerError>().having(
            (e) => e.toString(),
            'message',
            contains('library.uri'),
          ),
        ),
      );
    });

    test(
      'finds stateless, stateful and transitive widget subclasses',
      () async {
        final scan = await _scan('''
import 'package:flutter/widgets.dart';

class Plain extends StatelessWidget {
  const Plain({super.key});
}

class Counter extends StatefulWidget {
  const Counter({super.key});
  @override
  State createState() => _CounterState();
}

class _CounterState extends State<Counter> {}

class BaseCard extends StatelessWidget {
  const BaseCard({super.key});
}

class FancyCard extends BaseCard {
  const FancyCard({super.key});
}

class Scope extends InheritedWidget {
  const Scope({super.key});
}
''');

        expect(_names(scan.named), [
          'BaseCard',
          'Counter',
          'FancyCard',
          'Plain',
          'Scope',
        ]);
        expect(scan.named.map((w) => w.libraryUri).toSet(), {
          '$_appUri/a.dart',
        });
      },
    );

    test('skips private widgets and counts them', () async {
      final scan = await _scan('''
import 'package:flutter/widgets.dart';

class Visible extends StatelessWidget {
  const Visible();
}

class _Hidden extends StatelessWidget {
  const _Hidden();
}

class _AlsoHidden extends Visible {
  const _AlsoHidden();
}
''');

      expect(_names(scan.named), ['Visible']);
      expect(scan.privateCount, 2);
    });

    test('ignores State objects and classes that are not widgets', () async {
      final scan = await _scan('''
import 'package:flutter/widgets.dart';

class Model {}

class Holder extends StatefulWidget {
  const Holder();
  @override
  State createState() => HolderState();
}

class HolderState extends State<Holder> {}
''');

      expect(_names(scan.named), ['Holder']);
    });

    test(
      'skips abstract and sealed widgets, which are never instantiated',
      () async {
        final scan = await _scan('''
import 'package:flutter/widgets.dart';

abstract class BaseScreen extends StatelessWidget {
  const BaseScreen();
}

sealed class Shape extends StatelessWidget {
  const Shape();
}

class Concrete extends BaseScreen {
  const Concrete();
}
''');

        expect(_names(scan.named), ['Concrete']);
      },
    );

    test('reports generic widgets instead of naming them', () async {
      final scan = await _scan('''
import 'package:flutter/widgets.dart';

class Picker<T> extends StatelessWidget {
  const Picker();
}

class Plain extends StatelessWidget {
  const Plain();
}
''');

      expect(_names(scan.named), ['Plain']);
      expect(_names(scan.generic), ['Picker']);
    });

    test('includes widgets declared in part files', () async {
      final project = await FixtureProject.create({
        'lib/a.dart': '''
import 'package:flutter/widgets.dart';
part 'a_part.dart';

class Whole extends StatelessWidget {
  const Whole();
}
''',
        'lib/a_part.dart': '''
part of 'a.dart';

class FromPart extends StatelessWidget {
  const FromPart();
}
''',
      });
      addTearDown(project.dispose);

      final scan = scanLibrary(await project.library('a.dart'));

      expect(_names(scan.named), ['FromPart', 'Whole']);
      expect(await project.isLibrary('a_part.dart'), isFalse);
    });

    test('only treats Flutter\'s own Widget as a widget', () async {
      final scan = await _scan(
        '''
import 'package:flutter/widgets.dart';
import 'package:impostor/impostor.dart' as impostor;

class Fake extends impostor.Widget {
  const Fake();
}

class Real extends StatelessWidget {
  const Real();
}
''',
        others: {'impostor': 'class Widget { const Widget(); }\n'},
      );

      expect(_names(scan.named), ['Real']);
    });
  });
}
