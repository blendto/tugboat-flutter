# Packaging and distribution

Status: current · Last verified: 2026-09-05

**Mobile monorepo** — one repository containing the C++ core, both platform
runtimes, and framework adapters, resolved by a native Dart pub workspace with
one shared `pubspec.lock` and orchestrated by **Melos 7** (ADR 0001).

**`capture-runtime` (Android)** — `com.gettugboat.sdk:capture-runtime` AAR,
distributed on **Maven Central** (currently `0.1.0`). The Flutter Android
plugin depends on the Maven artifact — it never compiles `platforms/android`
from source. Local builds land in untracked `.local-maven/`.

**`TugboatCaptureRuntime` (Apple)** — CocoaPods pod (also installable via
SwiftPM), iOS 15+, currently `0.1.1` on CocoaPods trunk.

**`tugboat` / `tugboat_dio` (pub.dev)** — the published Flutter packages.
Public SDK imports use `package:tugboat/tugboat.dart`. The C++ core is never
copied into the pub package.

**Independent versioning** (ADR 0008) — every published artifact versions and
changelogs independently: the Flutter adapter, the AAR, and the Apple runtime
do not share a version line. Pins between them (e.g. the plugin's
capture-runtime pin) are checked by `tool/ci/check-version-policy.sh`,
`check-flutter-apple-pin-published.sh`, and the runtime API verifiers.

**Pin** — the recorded compatibility binding between a published package
version and the native runtime version it requires. Pin updates go through
the `tool/ci` pin scripts (some open PRs automatically).
