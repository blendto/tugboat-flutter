/// Builder options read from the host's `build.yaml`.
class WidgetNamesOptions {
  const WidgetNamesOptions({
    this.variableName = defaultVariableName,
    this.exclude = const [],
  });

  /// Reads and validates the `options:` block of the builder.
  ///
  /// Throws an [ArgumentError] for an unknown key or a malformed value, so a
  /// typo in `build.yaml` fails the build instead of being ignored.
  factory WidgetNamesOptions.fromConfig(Map<String, dynamic> config) {
    final unknown = config.keys.where((key) => !_knownKeys.contains(key));
    if (unknown.isNotEmpty) {
      throw ArgumentError(
        'Unknown tugboat_widget_names option(s): ${unknown.join(', ')}. '
        'Supported: ${_knownKeys.join(', ')}.',
      );
    }
    return WidgetNamesOptions(
      variableName: _variableName(config['variable_name']),
      exclude: _globs(config['exclude']),
    );
  }

  static const String defaultVariableName = 'tugboatWidgetNames';
  static const List<String> _knownKeys = ['variable_name', 'exclude'];

  /// Name of the generated `const Map<Type, String>`.
  final String variableName;

  /// Globs, relative to the package root, of libraries to leave out (for
  /// example `lib/web/**` for libraries that only compile for the web).
  final List<String> exclude;

  static final RegExp _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static final RegExp _importPrefix = RegExp(r'^_i\d+$');

  /// Words Dart does not allow as an identifier.
  static const Set<String> _reservedWords = {
    'assert',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'default',
    'do',
    'else',
    'enum',
    'extends',
    'false',
    'final',
    'finally',
    'for',
    'if',
    'in',
    'is',
    'new',
    'null',
    'rethrow',
    'return',
    'super',
    'switch',
    'this',
    'throw',
    'true',
    'try',
    'var',
    'void',
    'while',
    'with',
  };

  static String _variableName(Object? value) {
    if (value == null) return defaultVariableName;
    final problem = value is String
        ? _variableNameProblem(value)
        : 'must be a string';
    if (problem == null) return value as String;
    throw ArgumentError.value(value, 'variable_name', problem);
  }

  /// Why [name] cannot name the generated public constant, or null if it can.
  static String? _variableNameProblem(String name) {
    if (!_identifier.hasMatch(name)) return 'must be a Dart identifier';
    if (_importPrefix.hasMatch(name)) {
      return 'clashes with the generated import prefixes (_i0, _i1, ...)';
    }
    if (name.startsWith('_')) {
      return 'must be public: a name starting with "_" cannot be imported '
          'from the library that configures the SDK';
    }
    if (_reservedWords.contains(name)) {
      return 'is a reserved word in Dart';
    }
    return null;
  }

  static List<String> _globs(Object? value) {
    if (value == null) return const [];
    if (value is List && value.every((glob) => glob is String)) {
      return List<String>.unmodifiable(value);
    }
    throw ArgumentError.value(value, 'exclude', 'must be a list of globs');
  }
}
