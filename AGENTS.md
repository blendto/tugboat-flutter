# Tugboat mobile (tugboat-flutter)

Mobile capture SDKs for Tugboat: what the app-side SDK records, how it is
identified, and how it leaves the device safely. This repo produces the
evidence that Context Graph later turns into Session Atlas — but ingestion
and enrichment live elsewhere; this repo owns only the capture contracts.

## What this repo is

A mobile monorepo (Dart pub workspace + Melos 7), not a single package:

- `core/image-processing` — portable C++ CPU core with a C ABI; never copied
  into the published pub package.
- `platforms/android` — `com.gettugboat.sdk:capture-runtime` AAR. The Flutter
  plugin consumes it from **Maven Central** (or untracked `.local-maven/`
  after a local build); it does not compile `platforms/android` from source.
- `platforms/apple` — `TugboatCaptureRuntime` (CocoaPods + SwiftPM, iOS 15+).
- `sdks/flutter/packages/tugboat` — the Flutter adapter/plugin (pub.dev);
  `tugboat_dio` — Dio network evidence; `example/` — demo app, not published.
- `sdks/react-native` — future adapter placeholder only.
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
  `dart run melos run test:sdk` / `dart run melos run test:dio`.
- Lint gate: `dart run melos run complexity` — `dallow` rejects cyclomatic complexity
  above 10. Do not weaken it; refactor or suppress narrowly.
- C++ core tests: `bash tool/ci/run-image-core-tests.sh`.
- Android AAR build: `bash tool/ci/build-android-runtime.sh` (NDK
  28.2.13676358, CMake 3.22.1).
- Version/pin discipline: `tool/ci/check-version-policy.sh`,
  `check-flutter-apple-pin-published.sh`, `verify-android-runtime-api.sh`,
  `verify-swift-api.sh`, `verify-native-capture-pigeon.sh` — run the relevant
  ones when touching native code or versions. Packages version and changelog
  independently (ADR 0008).
- Requires Flutter 3.35+, Dart 3.9.2+.
- Cross-repo: host-app integration and end-to-end validation target is
  `mobile_app/` (see workspace `AGENTS.md`). Capture-contract changes must be
  checked against both sides.
