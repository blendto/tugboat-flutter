# CI tiers

**Quick tier: every push.** Runs on every push to a pull request and every
push to `main`, for each workflow whose files changed (its `paths` list).
Pushes to a branch without a pull request run nothing. A new push to a pull
request cancels its previous runs; runs on `main` are never cancelled.

| Workflow | Runs when these change | What it checks |
|---|---|---|
| `flutter-adapter.yml` | `sdks/flutter/`, `conformance/`, root pubspec, its scripts | Format, analyze, Pigeon outputs, package tests (including the example's checklist and smoke test on the host renderer), pub publish dry-run |
| `image-core.yml` | `core/`, `conformance/`, its scripts | C++ image core and session engine with ASan/UBSan, short fuzz runs |
| `apple-runtime.yml` | `TugboatCaptureRuntime.podspec`, `Package.swift`, `platforms/apple/`, `core/image-processing/` | `pod lib lint` of TugboatCaptureRuntime |
| `version-bump-check.yml` | always (pull requests only) | Version policy, API surfaces, pins |

When a workflow starts reading files outside its list, add them to its
`paths`, or a change there goes unchecked.

**Device tier: pull requests labelled `device-report`.** Runs on every push
while the label is on; remove the label to stop. Also available from the
Actions tab.

| Workflow | What it checks |
|---|---|
| `device-suite.yml` | The example on an Android emulator and an iOS simulator: feature checklist and capture benchmarks, built from the in-repo SDK and runtimes; the report is posted as a PR comment |
| `android-runtime.yml` | Android runtime build, unit tests, API dump, plugin compiled against the pinned and the in-repo runtime |
| `android-runtime-device.yml` | Android runtime instrumented tests on API 26 and 34 emulators |
| `apple-host.yml` | Swift host build and tests, SwiftUI sample and its UI tests, TugboatAlamofire |

**Full tier: daily.** `nightly.yml` runs at 02:00 UTC on `main`, Android only
for now: `device-suite.yml` (Android), `android-runtime.yml` and
`android-runtime-device.yml`.

`device-suite.yml`, `android-runtime.yml` and `android-runtime-device.yml`
can also be called from other workflows (see the comment at the top of
`device-suite.yml` for the permissions a caller must grant).

Nothing is a required check; release tags run their own publish workflows.
