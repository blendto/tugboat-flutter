# Capture backend profiling

`capture_profile_test.dart` drives a fixed script (browse feed flings,
expand/collapse, catalog, scroll playground, privacy fixture) and reports
capture cost, UI frame timings and RSS for one screenshot backend.

Run it on a physical device in profile mode, once per backend:

```sh
cd sdks/flutter/packages/tugboat/example
TBPROF_OUT=profile_flutter flutter drive --profile -d <device-id> \
  --driver test_driver/integration_test.dart \
  --target integration_test/capture_profile_test.dart \
  --dart-define=TUGBOAT_PROFILE=true \
  --dart-define=TUGBOAT_BACKEND=flutterRepaintBoundary

TBPROF_OUT=profile_native flutter drive --profile -d <device-id> \
  --driver test_driver/integration_test.dart \
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
