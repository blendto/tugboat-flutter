import 'package:glob/glob.dart';

import 'widget_names_options.dart';
import 'widget_names_renderer.dart';
import 'widget_scan.dart';

/// Scans the library at a package-relative path such as `lib/home.dart`.
/// Returns null for a file that is not a library (a `part` file: its classes
/// belong to the library it is `part of`).
typedef LibraryScanner = Future<LibraryScan?> Function(String path);

/// Collects the widgets of every library under `paths` and renders the
/// generated source.
///
/// This is the whole generator except for the `build_runner` plumbing, so it
/// has no dependency on `package:build`. A file that fails to scan is reported
/// through [onWarning] and skipped, so one broken file cannot hide every other
/// widget. Two outcomes are never silent:
///
/// - If every scanned library failed, or the analyzer lacks a member the
///   scanner needs ([UnsupportedAnalyzerError]), this throws, so an empty map
///   is never written as if the scan had succeeded.
/// - If the scan succeeded but found nothing to name, [onWarning] gets a
///   prominent message.
Future<String> generateWidgetNamesSource({
  required String package,
  required Stream<String> paths,
  required LibraryScanner scanLibraryAt,
  WidgetNamesOptions options = const WidgetNamesOptions(),
  void Function(String message)? onWarning,
}) async {
  final excluded = options.exclude.map(Glob.new).toList();
  final output = 'lib/$widgetNamesFileName';
  final named = <WidgetClass>[];
  final generic = <WidgetClass>[];
  var privateCount = 0;
  final failures = <String>[];
  var scanned = 0;
  await for (final path in paths) {
    if (path == output || excluded.any((glob) => glob.matches(path))) continue;
    final scan = await _scanOrNull(path, scanLibraryAt, onWarning, failures);
    if (scan == null) continue;
    scanned++;
    named.addAll(scan.named.where((w) => _isInPackage(w, package)));
    generic.addAll(scan.generic);
    privateCount += scan.privateCount;
  }
  _checkOutcome(scanned, failures, named, onWarning);
  return renderWidgetNames(
    variableName: options.variableName,
    named: named,
    generic: generic,
    privateCount: privateCount,
  );
}

/// The generated file can only `import` a library through its own package.
bool _isInPackage(WidgetClass widget, String package) =>
    widget.libraryUri.startsWith('package:$package/');

/// Scans one path. A missing analyzer member is fatal and propagates; any
/// other failure is recorded in [failures] and reported through [onWarning].
Future<LibraryScan?> _scanOrNull(
  String path,
  LibraryScanner scanLibraryAt,
  void Function(String message)? onWarning,
  List<String> failures,
) async {
  try {
    return await scanLibraryAt(path);
  } on UnsupportedAnalyzerError {
    rethrow;
  } on Object catch (error) {
    failures.add('$path: $error');
    onWarning?.call('Skipping $path: $error');
    return null;
  }
}

/// [scanned] counts libraries that scanned successfully; [failures] those that
/// did not.
void _checkOutcome(
  int scanned,
  List<String> failures,
  List<WidgetClass> named,
  void Function(String message)? onWarning,
) {
  if (scanned == 0 && failures.isNotEmpty) {
    throw StateError(
      'tugboat_widget_names: every library failed to scan '
      '(${failures.length}), so no widget map was written. First failure: '
      '${failures.first}',
    );
  }
  if (named.isEmpty) {
    onWarning?.call(
      'tugboat_widget_names: the generated widget map is EMPTY. No public, '
      'concrete, non-generic Flutter widget classes were found in this '
      "package's lib/ (widgets may live in other packages, be private, be "
      'generic, or be excluded). The SDK will not name any widget from this '
      'map.',
    );
  }
}
