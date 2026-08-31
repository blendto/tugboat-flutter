# CPU capture device results

Status: **not measured**. This VM has no physical Android device.
`nativeCpuExperimental` remains opt-in (P7.39).

Fill one row per device class after following
[cpu-capture-method.md](cpu-capture-method.md). Percentiles are microseconds
unless noted. Leave cells blank rather than inventing numbers.

| Device class | Backend | Scenario | n | p50 | p90 | p95 | worst | UI-isolate p95 | peak RSS | dropped frames | JPEG bytes | Gate |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| mid-range | flutterRepaintBoundary | — | | | | | | | | | | not run |
| mid-range | nativeCpuExperimental | — | | | | | | | | | | not run |
| flagship | flutterRepaintBoundary | — | | | | | | | | | | not run |
| flagship | nativeCpuExperimental | — | | | | | | | | | | not run |

Failed device classes: none recorded (no runs).

Battery (idle vs active, 10 minutes): not run.
