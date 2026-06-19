library;

import 'package:build/build.dart';

import 'src/widget_catalog_builder.dart';

Builder tugboatWidgetCatalogBuilder(BuilderOptions options) {
  final config = options.config;
  return TugboatWidgetCatalogBuilder(
    outputPath:
        config['output_path'] as String? ??
        TugboatWidgetCatalogBuilder.defaultOutputPath,
    scanDirectories:
        (config['scan_directories'] as List<dynamic>?)
            ?.whereType<String>()
            .toList() ??
        TugboatWidgetCatalogBuilder.defaultScanDirectories,
    variableName:
        config['variable_name'] as String? ??
        TugboatWidgetCatalogBuilder.defaultVariableName,
  );
}
