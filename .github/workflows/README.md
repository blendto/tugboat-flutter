# CI tiers

**Quick tier: every push.** Runs on every push to a pull request and every
push to `main`, for every stack, whatever files changed. Pushes to a branch
without a pull request run nothing. A new push to a pull request cancels its
previous runs; runs on `main` are never cancelled.

| Workflow | What it checks |
|---|---|
| `flutter-adapter.yml` | Format, analyze, Pigeon outputs, package tests (including the example's checklist and smoke test on the host renderer), pub publish dry-run |
| `image-core.yml` | C++ image core and session engine with ASan/UBSan, short fuzz runs |
| `android-runtime.yml` | Android runtime build, unit tests, API dump, plugin compiled against the pinned and the in-repo runtime |
| `apple-runtime.yml` | `pod lib lint` of TugboatCaptureRuntime |
| `apple-host.yml` | Swift host build and tests, SwiftUI sample and its UI tests, TugboatAlamofire |
| `version-bump-check.yml` | Version policy, API surfaces, pins (pull requests only) |

**Full tier: daily.** `nightly.yml` runs at 02:00 UTC on `main`, Android only
for now:

| Workflow | What it checks |
|---|---|
| `device-suite.yml` (Android) | The example on an emulator: feature checklist and capture benchmarks, built from the in-repo SDK and capture-runtime |
| `android-runtime-device.yml` | Android runtime instrumented tests on API 26 and 34 emulators |

Both full-tier workflows also run on demand from the Actions tab.
`device-suite.yml` also runs on a pull request labelled `device-report`
(both platforms, report posted as a PR comment) and can be called from other
workflows (see the comment at its top).

Nothing is a required check; release tags run their own publish workflows.
