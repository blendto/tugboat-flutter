# Device tests

- `capture_smoke_test.dart`: one end-to-end pass over the public API. Must
  pass.
- `device_checklist_test.dart`: one independent row per capture feature.
  A failing row is recorded with its reason and does not fail the run.
- `capture_profile_test.dart`: capture backend benchmark (below).

The device suite workflow (`.github/workflows/device-suite.yml`) runs the
checklist and the profile (2 rounds per backend) on an Android emulator and
an iOS simulator through
`tool/ci/device-report/run-device-suite.sh`, and
`tool/ci/device-report/render-report.py` renders the results as one report.
It is not a merge gate and runs only when asked for:

- Actions tab, "Device suite", "Run workflow" (optionally a ref, the
  platforms, and a PR number to post the report on).
- A pull request labelled `device-report`: the suite runs on every push
  while the label is on and keeps one PR comment up to date. A run that
  does not finish leaves the last full report in place and marks it out of
  date.
- Another workflow, with `uses: ./.github/workflows/device-suite.yml`.

# Capture backend profiling

`capture_profile_test.dart` drives a fixed script (browse feed flings,
expand/collapse, catalog, scroll playground, privacy fixture) and reports
capture cost, UI frame timings and RSS for one screenshot backend.

Run it on a physical device in profile mode, once per backend:

```sh
cd sdks/flutter/packages/tugboat/example
TBPROF_OUT=profile_flutter flutter drive --profile -d <device-id> \
  --driver test_driver/integration_driver.dart \
  --target integration_test/capture_profile_test.dart \
  --dart-define=TUGBOAT_PROFILE=true \
  --dart-define=TUGBOAT_BACKEND=flutterRepaintBoundary

TBPROF_OUT=profile_native flutter drive --profile -d <device-id> \
  --driver test_driver/integration_driver.dart \
  --target integration_test/capture_profile_test.dart \
  --dart-define=TUGBOAT_PROFILE=true \
  --dart-define=TUGBOAT_BACKEND=nativeCpuExperimental
```

Results land in `build/<TBPROF_OUT>.json` and as a `TBPROF {...}` log line.
`TUGBOAT_PROFILE_ROUNDS` (default 3) sets script repetitions.

Reading the summary:

- `captureMicros`: per fresh frame, frame wait + capture + mask + encode. On
  the native path, encode is the Pigeon round-trip.
- `nativeStageMicros`: runtime stages from `capture_diagnostic` events
  (native path only).
- `uiJankFrames`, `uiBuildMicros`, `uiRasterMicros`: host app frames over
  16.7 ms build or raster while capture runs.
- `rssBytes`: 100 ms RSS samples; short peaks can fall between samples.
- `frames` differs between backends when the screenshot budget skips
  eligible captures. Compare it alongside latency.

These numbers are lab evidence, not shipping claims.
