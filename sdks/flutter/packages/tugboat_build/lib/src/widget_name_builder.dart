import 'package:build/build.dart';
import 'package:glob/glob.dart';

import 'widget_name_generation.dart';
import 'widget_names_options.dart';
import 'widget_names_renderer.dart';
import 'widget_scan.dart';

/// Creates the builder; referenced from this package's `build.yaml`.
Builder tugboatWidgetNamesBuilder(BuilderOptions options) =>
    TugboatWidgetNamesBuilder(WidgetNamesOptions.fromConfig(options.config));

/// Writes `lib/tugboat_widget_names.g.dart`: a `const Map<Type, String>` of
/// every public, concrete, non-generic Flutter widget class declared in the
/// package's `lib/` directory, keyed by the class and valued by its source
/// name. Pass it to `TugboatReplayConfig.widgetNames`.
///
/// This class only connects `build_runner` to [generateWidgetNamesSource].
class TugboatWidgetNamesBuilder implements Builder {
  TugboatWidgetNamesBuilder([this.options = const WidgetNamesOptions()]);

  final WidgetNamesOptions options;

  @override
  Map<String, List<String>> get buildExtensions => const {
    r'$lib$': [widgetNamesFileName],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final package = buildStep.inputId.package;
    final source = await generateWidgetNamesSource(
      package: package,
      paths: buildStep.findAssets(Glob('lib/**.dart')).map((id) => id.path),
      scanLibraryAt: (path) =>
          _scan(buildStep.resolver, AssetId(package, path)),
      options: options,
      onWarning: log.warning,
    );
    final output = AssetId(package, 'lib/$widgetNamesFileName');
    await buildStep.writeAsString(output, source);
    log.info('Wrote $output');
  }

  Future<LibraryScan?> _scan(Resolver resolver, AssetId id) async {
    if (!await resolver.isLibrary(id)) return null;
    return scanLibrary(await resolver.libraryFor(id));
  }
}
