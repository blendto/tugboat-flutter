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
    final packagePubspec = File(
      '${directory.path}/packages/tugboat/pubspec.yaml',
    );
    if (packagePubspec.existsSync()) return packagePubspec;

    final currentPubspec = File('${directory.path}/pubspec.yaml');
    if (currentPubspec.existsSync()) {
      final contents = currentPubspec.readAsStringSync();
      if (RegExp(r'^name:\s*tugboat\s*$', multiLine: true).hasMatch(contents)) {
        return currentPubspec;
      }
    }

    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not find packages/tugboat/pubspec.yaml');
    }
    directory = parent;
  }
}
