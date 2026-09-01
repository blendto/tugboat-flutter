# Release process

Adapters and native runtimes version independently. See
[0008](../decisions/0008-independent-versioning.md) and
[compatibility.md](compatibility.md).

## Local (this milestone)

1. `bash tool/ci/run-image-core-tests.sh`
2. `bash tool/ci/build-android-runtime.sh` — publishes `.local-maven`
3. `bash tool/ci/run-flutter-tests.sh`
4. `bash tool/ci/verify-native-capture-pigeon.sh`
5. `bash tool/ci/check-license.sh`
6. `bash tool/ci/verify-android-runtime-api.sh`
7. `BASE_SHA=<pr-base> bash tool/ci/check-version-policy.sh`

Do not publish Maven Central or CocoaPods until privacy and performance
gates pass. Flutter `tugboat` / `tugboat_dio` `0.8.x` already publish to
pub.dev. Production replay acceptance is an internal canary, not a public
docs procedure.

## Version policy

- Documentation-only and C++ test/fuzz-only changes do not bump Flutter.
- Public Kotlin API or C ABI header changes bump `capture-runtime`.
- Flutter adapter source (`lib/`, `android/`, `ios/`, `pigeons/`, `pubspec.yaml`)
  bumps `tugboat` and updates this compatibility table.
- A runtime public API change that adapters consume also updates the table.

## pub.dev (Flutter 0.8.x)

Merging a Flutter version bump to `main` creates tag `v<version>` and
publishes `tugboat` and `tugboat_dio` from
`sdks/flutter/packages/`. pub.dev GitHub Actions must be enabled on both
package Admin tabs with repository `blendto/tugboat-flutter`, tag pattern
`v{{version}}`, and both `push` and `workflow_dispatch` events. Hosts should
depend on the hosted packages, not a GitHub git dependency.

## After native gates pass

1. Tag `capture-runtime-v0.1.0` and publish the AAR.
2. Point the Flutter plugin at the published coordinate.
3. Bump Flutter to `0.9.0`, keep native capture opt-in.
4. Tag `v0.9.0` (same pattern as 0.8.x) so GitHub Actions publishes the pub packages.
