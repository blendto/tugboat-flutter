# Tugboat example

Demo app and integration fixture for `package:tugboat`. It is not a separate
package. Run it from a clone of this repository:

```sh
cd sdks/flutter/packages/tugboat/example
flutter run
```

The example is a Dart workspace member (`resolution: workspace` in
`pubspec.yaml`), so `flutter run` needs the enclosing repo workspace. pub.dev
includes this folder with the hosted package for illustration; unpacking that
archive is not a standalone app.

## SDK integration smoke test

Boot an Android emulator or iOS simulator, then run these commands from the
example directory:

```sh
flutter devices
flutter test -d <device-id> integration_test/capture_smoke_test.dart
```

The test launches a small Flutter fixture and checks the evidence delivered to
an in-memory sink. It covers named navigation, scene inventory, repeatable tap
fingerprints, and privacy masking in a real encoded frame. No collector is
required. The Flutter integration workflow runs both platforms on relevant
pull requests and supports manual runs.
