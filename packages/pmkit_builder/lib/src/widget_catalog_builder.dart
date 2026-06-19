import 'dart:async';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:build/build.dart';
import 'package:glob/glob.dart';

class PmkitWidgetCatalogBuilder extends Builder {
  PmkitWidgetCatalogBuilder({
    this.outputPath = defaultOutputPath,
    this.scanDirectories = defaultScanDirectories,
    this.variableName = defaultVariableName,
  }) : buildExtensions = {
         r'$lib$': [
           outputPath.startsWith('lib/') ? outputPath.substring(4) : outputPath,
         ],
       };

  static const defaultOutputPath = 'lib/pmkit_widgets.g.dart';
  static const defaultScanDirectories = ['lib'];
  static const defaultVariableName = 'pmkitWidgetNames';

  final String outputPath;
  final List<String> scanDirectories;
  final String variableName;

  @override
  final Map<String, List<String>> buildExtensions;

  @override
  Future<void> build(BuildStep buildStep) async {
    if (!buildStep.inputId.path.endsWith(r'lib/$lib$')) return;

    final widgets = <String, InterfaceElement2>{};
    for (final directory in scanDirectories) {
      await for (final asset in buildStep.findAssets(
        Glob('$directory/**.dart'),
      )) {
        if (asset.path.endsWith('.g.dart') || asset.path == outputPath) {
          continue;
        }
        if (!await buildStep.resolver.isLibrary(asset)) continue;

        try {
          final library = await buildStep.resolver.libraryFor(asset);
          for (final element in library.classes) {
            _addWidget(element, widgets, includeCurrentPackageOnly: true);
          }

          final resolved = await library.session.getResolvedLibraryByElement2(
            library,
          );
          if (resolved is ResolvedLibraryResult) {
            for (final unit in resolved.units) {
              final visitor = _WidgetUseVisitor(widgets);
              unit.unit.accept(visitor);
            }
          }
        } catch (error) {
          log.warning('Unable to inspect ${asset.path}: $error');
        }
      }
    }

    final output = AssetId(buildStep.inputId.package, outputPath);
    await buildStep.writeAsString(
      output,
      _generate(buildStep.inputId.package, widgets),
    );
  }

  void _addWidget(
    InterfaceElement2 element,
    Map<String, InterfaceElement2> widgets, {
    required bool includeCurrentPackageOnly,
  }) {
    final name = element.name3;
    if (name == null || name.startsWith('_') || !_extendsWidget(element, {})) {
      return;
    }
    if (_baseWidgetNames.contains(name)) return;
    final uri = element.library2.uri;
    if (uri.scheme == 'dart' ||
        (includeCurrentPackageOnly &&
            uri.scheme == 'package' &&
            uri.pathSegments.first == 'flutter')) {
      return;
    }
    widgets[name] = element;
  }

  String _generate(String packageName, Map<String, InterfaceElement2> widgets) {
    final imports = <String>{};
    for (final element in widgets.values) {
      final uri = element.library2.uri;
      if (uri.scheme == 'package') {
        imports.add("import '$uri';");
      } else if (uri.scheme == 'file') {
        final marker = '/lib/';
        final path = uri.path;
        final index = path.lastIndexOf(marker);
        if (index >= 0) {
          imports.add(
            "import 'package:$packageName/${path.substring(index + marker.length)}';",
          );
        }
      }
    }

    final buffer = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
      ..writeln('// ignore_for_file: implementation_imports, unused_import')
      ..writeln();
    final sortedImports = imports.toList()..sort();
    for (final import in sortedImports) {
      buffer.writeln(import);
    }
    buffer
      ..writeln()
      ..writeln('const Map<Type, String> $variableName = {');
    final names = widgets.keys.toList()..sort();
    for (final name in names) {
      buffer.writeln("  $name: '$name',");
    }
    buffer.writeln('};');
    return buffer.toString();
  }
}

class _WidgetUseVisitor extends RecursiveAstVisitor<void> {
  _WidgetUseVisitor(this.widgets);

  final Map<String, InterfaceElement2> widgets;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final element = node.staticType?.element3;
    final name = element?.name3;
    if (element is InterfaceElement2 &&
        name != null &&
        !name.startsWith('_') &&
        !_baseWidgetNames.contains(name) &&
        _extendsWidget(element, {})) {
      final uri = element.library2.uri;
      if (uri.scheme != 'dart' &&
          !(uri.scheme == 'package' && uri.pathSegments.first == 'flutter')) {
        widgets[name] = element;
      }
    }
    super.visitInstanceCreationExpression(node);
  }
}

const _baseWidgetNames = {
  'Widget',
  'StatelessWidget',
  'StatefulWidget',
  'InheritedWidget',
  'RenderObjectWidget',
  'ProxyWidget',
};

bool _extendsWidget(InterfaceElement2 element, Set<InterfaceElement2> visited) {
  if (!visited.add(element)) return false;
  if (element.name3 == 'Widget' &&
      element.library2.uri.toString().contains('flutter')) {
    return true;
  }
  if (element is ClassElement2) {
    final supertype = element.supertype;
    if (supertype != null && _extendsWidget(supertype.element3, visited)) {
      return true;
    }
    for (final mixin in element.mixins) {
      if (_extendsWidget(mixin.element3, visited)) return true;
    }
  }
  return false;
}
