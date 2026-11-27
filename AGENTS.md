# Tugboat mobile (tugboat-flutter)

Mobile capture SDKs for Tugboat: what the app-side SDK records, how it is
identified, and how it leaves the device safely. This repo produces the
evidence that Context Graph later turns into Session Atlas — but ingestion
and enrichment live elsewhere; this repo owns only the capture contracts.

## What this repo is

A mobile monorepo (Dart pub workspace + Melos 7), not a single package:

- `core/image-processing` — portable C++ CPU core with a C ABI; never copied
  into the published pub package.
- `core/session-engine` — I/O-free C++ session engine behind a versioned C ABI
  (ADR 0009); built into the native Android (`tugboat-android`) and Swift
  (`Tugboat`) SDKs, not yet into Flutter. `conformance/` holds the golden
  fixtures it must match; the Dart SDK runs the kinds it still matches
  (`bash tool/ci/run-session-engine-tests.sh`).
- `platforms/android` — `com.gettugboat.sdk:capture-runtime` AAR. The Flutter
  plugin consumes it from **Maven Central** (or untracked `.local-maven/`
  after a local build); it does not compile `platforms/android` from source.
- `platforms/apple` — `TugboatCaptureRuntime` (CocoaPods + SwiftPM, iOS 15+).
- `sdks/flutter/packages/tugboat` — the Flutter adapter/plugin (pub.dev);
  `tugboat_dio` — Dio network evidence; `tugboat_build` — `build_runner`
  generator for the `widgetNames` map (not published yet); `example/` — demo
  app, not published.
- `sdks/react-native` — `@tugboat/react-native` 0.0.6, Android and iOS, unpublished
  (a TurboModule over `tugboat-android` and the Swift host); `example/` — demo app.
- `tool/ci` — host scripts for tests, builds, pins, API dumps, release checks.
- `docs/` — public contracts; `docs/publishing.md` rules what belongs there.
  Working notes (plans, lab gates, canaries) are not product docs.
  `docs/design/capture-and-fingerprint.md` is authoritative for identity,
  the Dart capture pipeline, and fingerprint schema. Native CPU privacy,
  coverage, fallback, diagnostics, and sink behavior are in
  `docs/architecture/native-capture-contracts.md`.

## Why the contracts look this way

- State and target identity are deterministic within one build + fingerprint
  schema version. **Cross-build stability is not promised** — consumers
  namespace by build metadata and `fingerprintSchemaVersion`.
- Screenshots are masked **before encoding** (`allTextAndMedia` default).
  On the default RepaintBoundary path, RGBA readback and mask-fill run in
  Dart (UI-isolate readback, encode-isolate fill). On native CPU capture,
  raw pixels never cross into Dart before masking.
- Locale is evidence, never identity.
- Capture or sink failures must never interrupt the host app; disabled
  lifecycle returns the host child unchanged.
- Changing identity, capture cadence, privacy boundaries, activation, or sink
  behavior can invalidate downstream evidence even if the Dart API stays
  source-compatible — treat those as contract changes.

Unfamiliar terms are defined in `docs/glossary/INDEX.md`.

## How to build, test, verify

- **dart + melos from the repo root, not per-package commands.** One shared
  `pubspec.lock` (native pub workspace). `dart pub get` first.
- `dart run melos run format`, `dart run melos run analyze`, and
  `dart run melos run test` — full workspace. Package-scoped:
  `dart run melos run test:sdk` / `dart run melos run test:dio` /
  `dart run melos run test:build`. `format` skips Pigeon output (`*.g.dart`);
  `format:check` is the CI form. Test files run in parallel; the wall-clock
  tap benchmark (tag `benchmark`) runs alone afterwards and CI skips it.
- CI (`.github/workflows/flutter-adapter.yml`) runs format, analyze and all
  three packages' tests on every pull request.
- C++ core tests: `bash tool/ci/run-image-core-tests.sh`.
- Android AAR build: `bash tool/ci/build-android-runtime.sh` (NDK
  28.2.13676358, CMake 3.22.1).
- Version/pin discipline: `tool/ci/check-version-policy.sh`,
  `check-flutter-apple-pin-published.sh`, `verify-android-runtime-api.sh`,
  `verify-swift-api.sh`, `verify-native-capture-pigeon.sh` — run the relevant
  ones when touching native code or versions. Native runtimes version independently (ADR 0008).
- Before opening or updating a PR to main that changes Flutter package source,
  a pub.dev README, or Dartdoc, bump `tugboat`, `tugboat_dio` and
  `tugboat_http` together; they always share one version. Use a patch for
  documentation. Update all three changelogs, the Dio, HTTP and example
  dependency floors, `lib/src/sdk_version.dart` in tugboat, and the compatibility
  table. Check open release PRs for collisions and run
  `BASE_SHA=origin/main bash tool/ci/check-version-policy.sh` against fresh main.
- Releases are tag-based: merging to `main` publishes nothing. A package is
  released by running its publish workflow on `main` or pushing its tag
  (`docs/releases/process.md`). Anything on `main` ships with the next tag,
  so unfinished work stays off by default.
- Requires Flutter 3.35+, Dart 3.9.2+.
- Cross-repo: host-app integration and end-to-end validation target is
  `mobile_app/` (see workspace `AGENTS.md`). Capture-contract changes must be
  checked against both sides.
