/// The library that declares Flutter's `Widget`. Every Flutter widget class
/// reaches it through its supertypes, whichever public library exports it.
const String flutterWidgetLibraryUri =
    'package:flutter/src/widgets/framework.dart';

/// A public, non-generic widget class the generated map can name.
class WidgetClass implements Comparable<WidgetClass> {
  const WidgetClass({required this.libraryUri, required this.name});

  /// The `package:` URI of the library that declares the class.
  final String libraryUri;

  /// The class name as written in source.
  final String name;

  @override
  int compareTo(WidgetClass other) {
    final byName = name.compareTo(other.name);
    return byName != 0 ? byName : libraryUri.compareTo(other.libraryUri);
  }

  @override
  bool operator ==(Object other) =>
      other is WidgetClass &&
      other.name == name &&
      other.libraryUri == libraryUri;

  @override
  int get hashCode => Object.hash(name, libraryUri);

  @override
  String toString() => '$libraryUri#$name';
}

/// The widget classes of one library, split by whether they can be named.
class LibraryScan {
  const LibraryScan({
    this.named = const [],
    this.generic = const [],
    this.privateCount = 0,
  });

  /// Public, concrete, non-generic widgets: these go in the map.
  final List<WidgetClass> named;

  /// Public, concrete widgets with type parameters: skipped, but reported.
  final List<WidgetClass> generic;

  /// Concrete widgets whose names start with `_`: no other library can
  /// reference them, so they are skipped.
  final int privateCount;
}

/// Thrown when the analyzer in use does not expose an element member this
/// package reads.
///
/// This is a hard error, not a skipped library: every library would hit it,
/// and the builder must fail instead of writing an empty map.
class UnsupportedAnalyzerError implements Exception {
  const UnsupportedAnalyzerError(this.member);

  /// The element member that could not be read, such as `class.isAbstract`.
  final String member;

  @override
  String toString() =>
      'UnsupportedAnalyzerError: cannot read `$member` from the analyzer '
      'element model. This version of tugboat_build does not support the '
      'analyzer your build_runner resolved; update tugboat_build.';
}

/// Classifies every class declared in [library] (including its `part` files).
///
/// [library] is the analyzer's `LibraryElement`. A builder cannot choose which
/// analyzer the host's `build_runner` brings, so this file does not import the
/// analyzer's element types: it reads every member it needs dynamically
/// through [_get]. Every member it reads has the same name in analyzer 8.0
/// through 14.x, the range this package's pubspec allows. A member the analyzer
/// in use does not provide throws [UnsupportedAnalyzerError] instead of a bare
/// [NoSuchMethodError].
LibraryScan scanLibrary(Object library) {
  final dynamic lib = library;
  final libraryUri = _uriOf(lib, 'library.uri');
  final named = <WidgetClass>[];
  final generic = <WidgetClass>[];
  var privateCount = 0;
  for (final dynamic element in _classesOf(lib)) {
    if (!_isConcreteWidget(element)) continue;
    final name = _nameOf(element);
    if (name == null) continue;
    if (_get('class.isPrivate', () => element.isPrivate as bool)) {
      privateCount++;
    } else {
      final widget = WidgetClass(libraryUri: libraryUri, name: name);
      (_hasTypeParameters(element) ? generic : named).add(widget);
    }
  }
  return LibraryScan(
    named: named,
    generic: generic,
    privateCount: privateCount,
  );
}

Iterable<dynamic> _classesOf(dynamic library) =>
    _get('library.classes', () => library.classes as Iterable);

String _uriOf(dynamic library, String member) =>
    _get(member, () => library.uri as Uri).toString();

/// Whether [element] can appear as a `widget.runtimeType`: it reaches
/// Flutter's `Widget` and can be instantiated.
bool _isConcreteWidget(dynamic element) {
  final isAbstract = _get('class.isAbstract', () => element.isAbstract as bool);
  final isSealed = _get('class.isSealed', () => element.isSealed as bool);
  if (isAbstract || isSealed) return false;
  final supertypes = _get(
    'class.allSupertypes',
    () => element.allSupertypes as Iterable,
  );
  return supertypes.any(_isFlutterWidget);
}

bool _isFlutterWidget(dynamic type) {
  final dynamic element = _get('type.element', () => type.element);
  if (_nameOf(element) != 'Widget') return false;
  final dynamic library = _get('element.library', () => element.library);
  return _uriOf(library, 'library.uri') == flutterWidgetLibraryUri;
}

String? _nameOf(dynamic element) =>
    _get('element.name', () => element.name) as String?;

bool _hasTypeParameters(dynamic element) {
  final parameters = _get(
    'class.typeParameters',
    () => element.typeParameters as Iterable,
  );
  return parameters.isNotEmpty;
}

/// Evaluates [read], which reads [member] from the analyzer's element model.
/// Throws [UnsupportedAnalyzerError] when the analyzer in use has no such
/// member.
T _get<T>(String member, T Function() read) {
  try {
    return read();
  } on NoSuchMethodError {
    throw UnsupportedAnalyzerError(member);
  }
}
