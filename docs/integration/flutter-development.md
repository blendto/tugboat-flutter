# Flutter development

Packages live under `sdks/flutter/packages`.

```sh
dart pub get
dart run melos run analyze
bash tool/ci/run-flutter-tests.sh tugboat
```

Regenerate Pigeon bridges after editing
`sdks/flutter/packages/tugboat/pigeons/native_capture.dart`:

```sh
bash tool/ci/generate-native-capture-pigeon.sh
```

CI fails if generated Dart/Kotlin/Swift drift. Do not dart-format Pigeon
outputs.

Screenshot pixels still default to `RepaintBoundary`. Enable native CPU
capture only through
`TugboatScreenshotCaptureBackend.nativeCpuExperimental`. In the monorepo and
on pub.dev, the Android plugin depends on Maven Central
`com.gettugboat.sdk:capture-runtime:0.1.0`. The iOS plugin depends on
CocoaPods `TugboatCaptureRuntime` `0.1.0` and requires iOS 15. The example
app path-overrides that pod to this repository. See
[native-cpu-experimental.md](native-cpu-experimental.md) and
[apple-development.md](apple-development.md).

Widget tests that wait on `SchedulerBinding.endOfFrame` hang. Native backend
widget tests use `waitForFrame: false` and a completed `frameWaiter`.
`NativeCaptureHostApi` is a concrete generated class; fakes extend it.
