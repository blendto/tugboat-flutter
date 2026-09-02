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

Do not publish Apple `TugboatCaptureRuntime` until privacy and performance
gates pass. Flutter `tugboat` / `tugboat_dio` `0.8.x` already publish to
pub.dev. Production replay acceptance is an internal canary, not a public
docs procedure.

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

## pub.dev (Flutter 0.8.x)

Merging a Flutter version bump to `main` creates tag `v<version>` and
publishes `tugboat` and `tugboat_dio` from
`sdks/flutter/packages/`. pub.dev GitHub Actions must be enabled on both
package Admin tabs with repository `blendto/tugboat-flutter`, tag pattern
`v{{version}}`, and both `push` and `workflow_dispatch` events. Hosts should
depend on the hosted packages, not a GitHub git dependency.

## Android AAR (`capture-runtime`)

Merging a `VERSION_NAME` bump to `main` creates tag `capture-runtime-v<version>`
and publishes `com.gettugboat.sdk:capture-runtime` from `platforms/android`.
`GITHUB_TOKEN` tag pushes do not start other workflows, so the tag job
dispatches `publish-android.yml` on that tag (same pattern as pub.dev).

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
still compiles from monorepo sources and stubs in published pub archives.

### Two-merge sequence for a new AAR

1. Runtime PR: bump `VERSION_NAME` (for example `0.1.1`) and merge. Wait until
   `publish-android.yml` has put that version on Maven Central (repo1 POM
   returns 200).
2. Flutter PR: pin
   `implementation("com.gettugboat.sdk:capture-runtime:<that version>")`,
   bump `tugboat` / `tugboat_dio`, and merge. That publishes to pub.dev.

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
5. Re-run `publish-android.yml` on tag `capture-runtime-v0.1.0` (or merge a
   version bump). The job skips GitHub Packages if that version already exists
   and publishes Central when the secrets are present.

## After native gates pass

1. Confirm `capture-runtime` `0.1.0` is on Maven Central (done for 0.8.14).
2. Point the Flutter plugin at the published coordinate (done in 0.8.14).
3. Bump Flutter to `0.9.0`, keep native capture opt-in until gates pass, then
   consider making native capture the default.
4. Tag `v0.9.0` (same pattern as 0.8.x) so GitHub Actions publishes the pub packages.
