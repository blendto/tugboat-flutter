import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/sdk_version.dart';

void main() {
  test('SDK version header matches pubspec version', () async {
    final pubspec = await _findTugboatPubspec().readAsString();
    final versionMatch = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(versionMatch, isNotNull);
    expect(tugboatSdkVersion, versionMatch!.group(1));
  });
}

File _findTugboatPubspec() {
  var directory = Directory.current;
  while (true) {
    final nested = File(
      '${directory.path}/sdks/flutter/packages/tugboat/pubspec.yaml',
    );
    if (nested.existsSync()) return nested;

    final currentPubspec = File('${directory.path}/pubspec.yaml');
    if (currentPubspec.existsSync()) {
      final contents = currentPubspec.readAsStringSync();
      if (RegExp(r'^name:\s*tugboat\s*$', multiLine: true).hasMatch(contents)) {
        return currentPubspec;
      }
    }

    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not find tugboat pubspec.yaml');
    }
    directory = parent;
  }
}
