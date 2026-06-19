library;

import 'package:build/build.dart';

import 'src/widget_catalog_builder.dart';

Builder pmkitWidgetCatalogBuilder(BuilderOptions options) {
  final config = options.config;
  return PmkitWidgetCatalogBuilder(
    outputPath:
        config['output_path'] as String? ??
        PmkitWidgetCatalogBuilder.defaultOutputPath,
    scanDirectories:
        (config['scan_directories'] as List<dynamic>?)
            ?.whereType<String>()
            .toList() ??
        PmkitWidgetCatalogBuilder.defaultScanDirectories,
    variableName:
        config['variable_name'] as String? ??
        PmkitWidgetCatalogBuilder.defaultVariableName,
  );
}
