# Common build

From the repository root:

```sh
dart pub get
bash tool/ci/run-image-core-tests.sh
bash tool/ci/build-android-runtime.sh
bash tool/ci/run-flutter-tests.sh
bash tool/ci/verify-native-capture-pigeon.sh
```

The Android AAR publishes to untracked `.local-maven/` for native Android
apps and the sample. The Flutter plugin compiles `capture-runtime` from
source when `platforms/android` is present, so example APKs do not need
that Maven artifact.

Release-control scripts (also run in CI):

```sh
BASE_SHA=<pr-base-sha> bash tool/ci/check-version-policy.sh
bash tool/ci/check-license.sh
bash tool/ci/verify-android-runtime-api.sh
bash tool/ci/verify-swift-api.sh
```

`dart pub publish --dry-run` is `bash tool/ci/pub-dry-run.sh`.

Apple: `Package.swift` at the repository root. Public Swift surface is
`platforms/apple/api.txt`. Simulator/device builds need Xcode.
