# Release process

Adapters and native runtimes version independently. See
[0008](../decisions/0008-independent-versioning.md) and
[compatibility.md](compatibility.md).

## Releases are tag-based

Merging to `main` never publishes anything. `main` can hold changes that are
not released yet, so unfinished work must be off by default or live in a
package that has no publish workflow.

Each package is released by a tag on a commit of `main`:

| Package | Tag | Workflow |
| --- | --- | --- |
| `tugboat`, `tugboat_dio` and `tugboat_http` (lockstep) | `v<version>` | **Publish to pub.dev** (`publish.yml`) |
| `com.gettugboat.sdk:capture-runtime` | `capture-runtime-v<version>` | **Publish Android runtime** (`publish-android.yml`) |
| `TugboatCaptureRuntime` | `apple-runtime-v<version>` | **Publish Apple runtime** (`publish-apple.yml`) |
| `com.gettugboat.sdk:tugboat-android` | `tugboat-android-v<version>` | **Publish Android SDK** (`publish-android-sdk.yml`) |
| `com.gettugboat.sdk:tugboat-okhttp` | `tugboat-okhttp-v<version>` | **Publish Android SDK** (`publish-android-sdk.yml`) |
| `TugboatSessionEngine` | `session-engine-v<version>` | **Publish Apple SDK** (`publish-apple-sdk.yml`) |
| `Tugboat` | `apple-host-v<version>` | **Publish Apple SDK** (`publish-apple-sdk.yml`) |
| `@tugboat-ai/react-native` | `react-native-v<version>` | **Publish React Native** (`publish-react-native.yml`) |

To cut a release:

1. Make sure the version in `pubspec.yaml`, `platforms/android/gradle.properties`
   (`VERSION_NAME`), `TugboatCaptureRuntime.podspec` (`s.version`) or
   `sdks/react-native/package.json` is the one to release, and that its changelog section is written.
2. Either run the package's workflow on `main` (Actions > the workflow > Run
   workflow, branch `main`), or push the tag yourself:
   `git tag -a v0.12.5 -m "tugboat 0.12.5" <commit> && git push origin v0.12.5`.
   The native SDK workflows (`publish-android-sdk.yml`, `publish-apple-sdk.yml`)
   release only from a pushed tag; run from the Actions tab, they are a dry
   run (see "Native SDKs").
3. Running the workflow on `main` (the `cut_release` job) checks that the
   version is not published yet, tags the current `main` commit, and
   dispatches the workflow on the tag. `GITHUB_TOKEN` tag pushes do not start
   other workflows, so the dispatch is what runs the publish.
4. On the tag, the publish jobs check that the tag matches the package
   version and skip anything already published, so re-running on a tag is
   safe.

To release a fix while `main` holds changes that are not ready, branch from
the last release tag, fix and bump there, and tag that branch's commit.

## Local (this milestone)

1. `bash tool/ci/run-image-core-tests.sh`
2. `bash tool/ci/build-android-runtime.sh` — publishes `.local-maven`
3. `bash tool/ci/run-flutter-tests.sh`
4. `bash tool/ci/verify-native-capture-pigeon.sh`
5. `bash tool/ci/check-license.sh`
6. `bash tool/ci/verify-android-runtime-api.sh`
7. `BASE_SHA=<pr-base> bash tool/ci/check-version-policy.sh`

Do not make native capture the default until privacy and performance gates
pass. Flutter `tugboat` / `tugboat_dio` `0.8.x` already publish to pub.dev.
Production replay acceptance is an internal canary, not a public docs
procedure.

## Version policy

- Documentation-only and C++ test/fuzz-only changes do not bump Flutter.
- Public Kotlin API or C ABI header changes bump `capture-runtime`
  (`VERSION_NAME` in `platforms/android/gradle.properties`).
- Flutter adapter source (`lib/`, `android/`, `ios/`, `pigeons/`, `pubspec.yaml`)
  bumps `tugboat` and updates this compatibility table.
- A runtime public API change that adapters consume also updates the table.
- The Flutter plugin's `capture-runtime` Maven pin must not be newer than
  `VERSION_NAME`. Changing the pin requires it to equal `VERSION_NAME`.
  Runtime-only PRs may leave the pin lagging until Central has the new AAR.
- The Flutter plugin's `TugboatCaptureRuntime` CocoaPods pin must not be
  newer than the root podspec `s.version`. Changing the pin requires it to
  equal that version. Runtime-only PRs may leave the pin lagging until trunk
  has the new pod.

## Native SDKs (Android `tugboat-android`, iOS `Tugboat`)

These release only by pushing the tag on a `main` commit; running the
workflow from the Actions tab is a dry run instead. On a branch it builds the
chosen module and prints its POM (Android), or lints the chosen podspec
against the checkout's sources (iOS), and publishes nothing. Use it before
tagging: Maven Central and CocoaPods trunk releases are permanent, and the
pod tags are also the podspecs' `s.source`.

Versions live in `val tugboatAndroidVersion` / `val tugboatOkHttpVersion`
(`platforms/android/<module>/build.gradle.kts`) and in the podspecs'
`s.version`. `Tugboat.podspec` pins `TugboatSessionEngine` and
`TugboatCaptureRuntime` exactly; bump those pins with them.

Release in dependency order, waiting for each to appear before the next:

1. `capture-runtime-v<version>` (Maven Central)
2. `tugboat-android-v<version>`, then `tugboat-okhttp-v<version>`
3. `apple-runtime-v<version>` (CocoaPods trunk)
4. `session-engine-v<version>`, then `apple-host-v<version>`

The Android job refuses to publish while a `com.gettugboat.sdk` dependency in
the module's POM is not on Maven Central
(`tool/ci/check-maven-pom-deps-published.sh`); `pod trunk push` fails on a
missing pod dependency. Both jobs fail if their registry secrets are missing
(`MAVEN_CENTRAL_*` and `MAVEN_GPG_*`, or `COCOAPODS_TRUNK_TOKEN`).

## npm (`@tugboat-ai/react-native`)

Tag `react-native-v<version>` publishes `sdks/react-native` to npm under the
`tugboat-ai` org. `package.json` `version` and `src/sdkVersion.ts` must match
the tag; the publish job checks both.

The package pins its native SDKs: `tugboatAndroidVersion` in
`android/build.gradle` (`com.gettugboat.sdk:tugboat-android` and
`tugboat-okhttp`) and the `Tugboat` dependency in
`TugboatReactNative.podspec`. `tool/ci/check-react-native-native-deps.sh`
fails the release until those versions are on Maven Central and CocoaPods
trunk, because an npm version cannot be republished once it is out. Publish
the native SDKs first.

Authentication is npm trusted publishing (GitHub Actions OIDC; npm adds
provenance). The trusted publisher is set on npmjs.com: the package's
**Settings** > **Trusted publishing**, GitHub Actions, organization
`blendto`, repository `tugboat-mobile-sdk`, workflow
`publish-react-native.yml`. A new trusted publisher expires unless it
publishes within 2 days. If npm will not let you add one before the package
exists:

1. First release: add a repository secret `NPM_TOKEN`, a granular npm token
   that can publish to the `tugboat-ai` scope, then release as above.
2. Within 2 days before the next release, add the trusted publisher.
3. After that release has gone out through OIDC, delete the `NPM_TOKEN`
   secret and revoke the token.

`package.json` `repository.url` must match the GitHub repository exactly, or
npm rejects the provenance.

## pub.dev (Flutter 0.8.x)

Tag `v<version>` publishes `tugboat` and `tugboat_dio` from
`sdks/flutter/packages/` (see "Releases are tag-based" above). pub.dev GitHub Actions must be enabled on both
package Admin tabs with repository `blendto/tugboat-flutter`, tag pattern
`v{{version}}`, and both `push` and `workflow_dispatch` events. Hosts should
depend on the hosted packages, not a GitHub git dependency.

## Android AAR (`capture-runtime`)

Tag `capture-runtime-v<version>` publishes `com.gettugboat.sdk:capture-runtime`
from `platforms/android`. Running the workflow on `main` creates that tag and
dispatches `publish-android.yml` on it (same pattern as pub.dev).

### GitHub Packages (default)

No extra secrets. The publish job uploads to

`https://maven.pkg.github.com/blendto/tugboat-flutter`

After the first successful publish, open the package on GitHub and set
visibility to **public** if native Android hosts should resolve it with only
a token. GitHub Packages still requires credentials for downloads.

The Blend org must allow GitHub Actions to create packages for this
repository (`packages: write` is already on the workflow).

Consumers need a GitHub token even for a public package:

```kotlin
repositories {
    maven {
        url = uri("https://maven.pkg.github.com/blendto/tugboat-flutter")
        credentials {
            username = providers.gradleProperty("gpr.user").orElse(System.getenv("GITHUB_ACTOR")).get()
            password = providers.gradleProperty("gpr.key").orElse(System.getenv("GITHUB_TOKEN")).get()
        }
    }
}
dependencies {
    implementation("com.gettugboat.sdk:capture-runtime:0.1.0")
}
```

The Flutter plugin depends on Maven Central
`com.gettugboat.sdk:capture-runtime:0.1.0`. Do not point it at GitHub
Packages; pub.dev hosts cannot supply GitHub credentials. iOS native capture
depends on CocoaPods `TugboatCaptureRuntime` `0.1.0` and requires iOS 15.

### Sequence for a new AAR

1. Runtime PR: bump `VERSION_NAME` (for example `0.1.1`) and merge. Release it
   with tag `capture-runtime-v0.1.1`, then wait until `publish-android.yml`
   has put that version on Maven Central (repo1 POM returns 200).
2. Flutter PR: pin
   `implementation("com.gettugboat.sdk:capture-runtime:<that version>")`,
   bump `tugboat` / `tugboat_dio`, and merge. Release it with tag
   `v<version>` to publish to pub.dev.

Do not merge a Flutter pin for a version that is not on repo1 yet. After a
`capture-runtime-v*` tag publish, `publish-android.yml` waits for repo1 and
opens `chore/pin-capture-runtime-<version>` when the plugin still lags. That
job is a no-op if the pin already matches `VERSION_NAME` or the branch/PR
already exists. Recovery: re-run **Publish Android runtime** on the tag.
The repository must allow GitHub Actions to create pull requests.

### Maven Central (public hosts)

Required before the Flutter plugin can depend on the AAR from pub.dev.

1. Create a Central Portal account at [central.sonatype.com](https://central.sonatype.com/).
2. Verify namespace `com.gettugboat` with a DNS TXT record on
   [gettugboat.com](https://gettugboat.com). That namespace covers
   `com.gettugboat.sdk`.
3. Generate a user token and a signing GPG key.
4. Add repository secrets:
   - `MAVEN_CENTRAL_USERNAME`
   - `MAVEN_CENTRAL_PASSWORD`
   - `MAVEN_GPG_KEY` (ASCII-armored private key)
   - `MAVEN_GPG_PASSPHRASE`
5. Re-run `publish-android.yml` on tag `capture-runtime-v0.1.0` (or release
   a new version). The job skips GitHub Packages if that version already exists
   and publishes Central when the secrets are present.

## Apple CocoaPod (`TugboatCaptureRuntime`)

Tag `apple-runtime-v<version>` runs `publish-apple.yml` (macOS `pod lib
lint` + `pod trunk push`). Running the workflow on `main` creates that tag when
trunk does not have the root podspec `s.version`. `s.source` uses that same tag. Trunk `0.1.0` was
published from `capture-runtime-v0.1.0` before this alignment; later versions
clone `apple-runtime-v<version>`. The tag is still created when trunk already
has the version so the git source exists.

Add repository secret `COCOAPODS_TRUNK_TOKEN` (from `pod trunk me` after
`pod trunk register`). Without it the job lints and skips the push.

The Flutter plugin depends on `TugboatCaptureRuntime` `0.1.0` from trunk and
sets the plugin floor to iOS 15. The example app path-overrides the pod to
this repository for unpublished runtime work.

### Sequence for a new Apple runtime

1. Runtime PR: bump `TugboatCaptureRuntime.podspec` `s.version` and merge.
   Release it with tag `apple-runtime-v<version>` and wait until trunk has
   that version.
2. Flutter PR: pin `s.dependency 'TugboatCaptureRuntime', '<that version>'`,
   bump `tugboat` / `tugboat_dio`, merge, and release with tag `v<version>`.

Do not merge a Flutter pin for a version that is not on trunk yet. After an
`apple-runtime-v*` publish, `publish-apple.yml` waits for trunk and opens
`chore/pin-tugboat-capture-runtime-<version>` when the plugin still lags.
Recovery: re-run **Publish Apple runtime** on the tag.

## After native gates pass

1. Confirm `capture-runtime` `0.1.0` is on Maven Central (done for 0.8.14).
2. Point the Flutter Android plugin at the published coordinate (done in 0.8.14).
3. Publish Apple `TugboatCaptureRuntime` `0.1.0` to CocoaPods (0.8.15) and keep
   native capture opt-in until gates pass, then consider making it the default.
4. Bump Flutter to `0.9.0` when native capture becomes the default.
5. Tag `v0.9.0` (same pattern as 0.8.x) so GitHub Actions publishes the pub packages.
