import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat_build/src/widget_name_generation.dart';
import 'package:tugboat_build/src/widget_names_options.dart';
import 'package:tugboat_build/src/widget_scan.dart';

import 'support/fixture_project.dart';

String _source(String name) =>
    '''
import 'package:flutter/widgets.dart';

class $name extends StatelessWidget {
  const $name();
}
''';

String _withoutLib(String path) => path.substring('lib/'.length);

/// Runs the generator over [paths] of [project], scanning with the real
/// analyzer the way the builder's resolver does.
Future<String> _generate(
  FixtureProject project,
  List<String> paths, {
  WidgetNamesOptions options = const WidgetNamesOptions(),
  Set<String> failing = const {},
  List<String>? warnings,
}) {
  return generateWidgetNamesSource(
    package: 'app',
    paths: Stream.fromIterable(paths),
    options: options,
    onWarning: warnings?.add,
    scanLibraryAt: (path) async {
      if (failing.contains(path)) throw StateError('cannot resolve $path');
      final libPath = _withoutLib(path);
      if (!await project.isLibrary(libPath)) return null;
      return scanLibrary(await project.library(libPath));
    },
  );
}

void main() {
  test(
    'names public widgets across libraries, skips private and non-widgets',
    () async {
      final project = await FixtureProject.create({
        'lib/home.dart': _source('HomeScreen'),
        'lib/src/card.dart': _source('CartCard'),
        'lib/src/private.dart': _source('_Hidden'),
        'lib/model.dart': 'class Model {}\n',
      });
      addTearDown(project.dispose);

      final output = await _generate(project, [
        'lib/home.dart',
        'lib/src/card.dart',
        'lib/src/private.dart',
        'lib/model.dart',
      ]);

      expect(output, contains("_i0.HomeScreen: 'HomeScreen',"));
      expect(output, contains("_i1.CartCard: 'CartCard',"));
      expect(output, isNot(contains('_Hidden:')));
      expect(output, contains('// - 1 private (leading underscore)'));
      expect(output, isNot(contains('Model')));
    },
  );

  test('output does not depend on the order assets are found in', () async {
    final project = await FixtureProject.create({
      'lib/a.dart': _source('Alpha'),
      'lib/b.dart': _source('Beta'),
      'lib/c.dart': _source('Gamma'),
    });
    addTearDown(project.dispose);

    final first = await _generate(project, [
      'lib/a.dart',
      'lib/b.dart',
      'lib/c.dart',
    ]);
    final second = await _generate(project, [
      'lib/c.dart',
      'lib/a.dart',
      'lib/b.dart',
    ]);

    expect(second, first);
  });

  test('does not read its own previous output', () async {
    final project = await FixtureProject.create({
      'lib/a.dart': _source('Alpha'),
      'lib/tugboat_widget_names.g.dart': _source('Stale'),
    });
    addTearDown(project.dispose);

    final output = await _generate(project, [
      'lib/a.dart',
      'lib/tugboat_widget_names.g.dart',
    ]);

    expect(output, contains("_i0.Alpha: 'Alpha',"));
    expect(output, isNot(contains('Stale')));
  });

  test('skips part files and still finds the widgets they declare', () async {
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

    final output = await _generate(project, ['lib/a.dart', 'lib/a_part.dart']);

    expect(output, contains("_i0.FromPart: 'FromPart',"));
    expect(output, contains("_i0.Whole: 'Whole',"));
    expect(output, isNot(contains('a_part.dart')));
  });

  test('honors the exclude globs', () async {
    final project = await FixtureProject.create({
      'lib/a.dart': _source('Alpha'),
      'lib/web/w.dart': _source('WebOnly'),
    });
    addTearDown(project.dispose);

    final output = await _generate(project, [
      'lib/a.dart',
      'lib/web/w.dart',
    ], options: const WidgetNamesOptions(exclude: ['lib/web/**']));

    expect(output, contains('Alpha'));
    expect(output, isNot(contains('WebOnly')));
  });

  test(
    'a library that fails to scan is reported and does not hide others',
    () async {
      final project = await FixtureProject.create({
        'lib/a.dart': _source('Alpha'),
        'lib/broken.dart': _source('Broken'),
      });
      addTearDown(project.dispose);
      final warnings = <String>[];

      final output = await _generate(
        project,
        ['lib/a.dart', 'lib/broken.dart'],
        failing: {'lib/broken.dart'},
        warnings: warnings,
      );

      expect(output, contains('Alpha'));
      expect(output, isNot(contains('Broken')));
      expect(warnings.single, contains('lib/broken.dart'));
    },
  );

  test('uses the configured variable name', () async {
    final project = await FixtureProject.create({
      'lib/a.dart': _source('Alpha'),
    });
    addTearDown(project.dispose);

    final output = await _generate(project, [
      'lib/a.dart',
    ], options: const WidgetNamesOptions(variableName: 'appNames'));

    expect(output, contains('const Map<Type, String> appNames = {'));
  });

  test(
    'throws when every scanned library fails, instead of an empty map',
    () async {
      final warnings = <String>[];

      await expectLater(
        generateWidgetNamesSource(
          package: 'app',
          paths: Stream.fromIterable(['lib/a.dart', 'lib/b.dart']),
          onWarning: warnings.add,
          scanLibraryAt: (path) async => throw StateError('boom in $path'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('every library failed'), contains('boom in')),
          ),
        ),
      );
      expect(warnings, hasLength(2));
    },
  );

  test('part files alone do not count as failures', () async {
    final warnings = <String>[];

    final output = await generateWidgetNamesSource(
      package: 'app',
      paths: Stream.fromIterable(['lib/a_part.dart']),
      onWarning: warnings.add,
      scanLibraryAt: (path) async => null,
    );

    expect(output, contains('const Map<Type, String> tugboatWidgetNames = {'));
    expect(warnings.single, contains('EMPTY'));
  });

  test(
    'an analyzer member that cannot be read is fatal, not skipped',
    () async {
      await expectLater(
        generateWidgetNamesSource(
          package: 'app',
          paths: Stream.fromIterable(['lib/a.dart', 'lib/b.dart']),
          // Scanning a bare object stands in for an analyzer without the
          // members this package reads.
          scanLibraryAt: (path) async => scanLibrary(Object()),
        ),
        throwsA(isA<UnsupportedAnalyzerError>()),
      );
    },
  );

  test('logs a prominent warning when the map ends up empty', () async {
    final project = await FixtureProject.create({
      'lib/a.dart': _source('_Hidden'),
      'lib/model.dart': 'class Model {}\n',
    });
    addTearDown(project.dispose);
    final warnings = <String>[];

    final output = await _generate(project, [
      'lib/a.dart',
      'lib/model.dart',
    ], warnings: warnings);

    expect(output, contains('const Map<Type, String> tugboatWidgetNames = {'));
    expect(warnings.single, contains('EMPTY'));
  });

  test('no empty-map warning when widgets were named', () async {
    final project = await FixtureProject.create({
      'lib/a.dart': _source('Alpha'),
    });
    addTearDown(project.dispose);
    final warnings = <String>[];

    await _generate(project, ['lib/a.dart'], warnings: warnings);

    expect(warnings, isEmpty);
  });
}
