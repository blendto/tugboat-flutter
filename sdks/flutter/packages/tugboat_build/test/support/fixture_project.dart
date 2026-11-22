import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/element/element.dart';

/// A stub of the one Flutter library the scanner looks for: the file that
/// declares `Widget`, at the same `package:` URI as the real framework.
const String stubFlutterFramework = '''
abstract class Widget {
  const Widget();
}

abstract class StatelessWidget extends Widget {
  const StatelessWidget();
}

abstract class StatefulWidget extends Widget {
  const StatefulWidget();
  State createState();
}

abstract class State<T extends StatefulWidget> {}

abstract class InheritedWidget extends Widget {
  const InheritedWidget();
}
''';

/// A throwaway on-disk package named `app` next to a stub `flutter` package,
/// analyzed with the real analyzer. Fixture sources exist only for the
/// duration of a test, so they never reach the repository's own analysis.
class FixtureProject {
  FixtureProject._(this.root, this._collection);

  /// Writes [appFiles] (paths relative to the package root, for example
  /// `lib/a.dart`) and starts an analysis context over them.
  static Future<FixtureProject> create(
    Map<String, String> appFiles, {
    Map<String, String> otherPackages = const {},
  }) async {
    final root = await Directory.systemTemp.createTemp('tugboat_build_');
    final appDir = Directory('${root.path}/app')..createSync();
    final packages = <String, String>{
      'app': appDir.path,
      'flutter': '${root.path}/flutter',
    };
    _write(packages['flutter']!, {
      'lib/src/widgets/framework.dart': stubFlutterFramework,
      'lib/widgets.dart': "export 'src/widgets/framework.dart';\n",
    });
    for (final entry in otherPackages.entries) {
      packages[entry.key] = '${root.path}/${entry.key}';
      _write(packages[entry.key]!, {'lib/${entry.key}.dart': entry.value});
    }
    _write(appDir.path, appFiles);
    _writePackageConfig(appDir.path, packages);
    final collection = AnalysisContextCollection(
      includedPaths: [appDir.path],
      sdkPath: _findSdkPath(),
    );
    return FixtureProject._(root, collection);
  }

  final Directory root;
  final AnalysisContextCollection _collection;

  String get appPath => '${root.path}/app';

  /// The element of the library `package:app/<libPath>`.
  Future<LibraryElement> library(String libPath) async {
    final result = await _session.getLibraryByUri('package:app/$libPath');
    if (result is! LibraryElementResult) {
      throw StateError('package:app/$libPath is not a library: $result');
    }
    return result.element;
  }

  /// Whether `lib/<libPath>` is a library rather than a `part` file.
  Future<bool> isLibrary(String libPath) async {
    final result = _session.getFile('$appPath/lib/$libPath');
    return result is FileResult && result.isLibrary;
  }

  /// Messages of every error-level diagnostic in `lib/<libPath>`.
  Future<List<String>> errors(String libPath) async {
    final result = await _session.getErrors('$appPath/lib/$libPath');
    if (result is! ErrorsResult) throw StateError('No errors result: $result');
    return [
      for (final diagnostic in result.diagnostics)
        if (diagnostic.severity.name == 'error')
          '${diagnostic.diagnosticCode.name}: ${diagnostic.message}',
    ];
  }

  Future<void> dispose() async {
    await _collection.dispose();
    await root.delete(recursive: true);
  }

  AnalysisSession get _session => _collection.contexts.single.currentSession;

  static void _write(String dir, Map<String, String> files) {
    for (final entry in files.entries) {
      File('$dir/${entry.key}')
        ..createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
  }

  static void _writePackageConfig(String appDir, Map<String, String> pkgs) {
    final entries = pkgs.entries
        .map(
          (e) =>
              '{"name":"${e.key}","rootUri":"${Uri.directory(e.value)}",'
              '"packageUri":"lib/","languageVersion":"3.9"}',
        )
        .join(',');
    File('$appDir/.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"configVersion":2,"packages":[$entries]}');
  }

  /// `flutter test` runs inside `flutter_tester`, so the analyzer cannot
  /// derive the Dart SDK from the running executable: look it up instead.
  static String _findSdkPath() {
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null) {
      final sdk = '$flutterRoot/bin/cache/dart-sdk';
      if (Directory(sdk).existsSync()) return sdk;
    }
    final executable = File(Platform.resolvedExecutable);
    final sdk = executable.parent.parent.path;
    if (File('$sdk/version').existsSync()) return sdk;
    throw StateError('Cannot locate the Dart SDK: set FLUTTER_ROOT.');
  }
}
