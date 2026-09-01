# Capture benchmarks

Device-lab instructions for Phase 7. Do not run these as CI on this host:
there is no Android device, and debug/emulator numbers are not gates.

1. Publish the local AAR: `bash tool/ci/build-android-runtime.sh`
2. Build a **release** example with the backend under test.
3. Enable `TugboatScreenshotCaptureBackend.nativeCpuExperimental` only for the
   native series. Keep `flutterRepaintBoundary` for the baseline series.
4. Warm up ≥ 30 captures; measure ≥ 200 per scenario.
5. Export `capture_diagnostic` timing fields plus RSS, CPU, dropped frames,
   and JPEG byte length.
6. Write percentiles into the internal lab results note
   (`internal/docs/lab/cpu-capture-results.md`).

Do not log pixel or JPEG payloads. Compare JPEG size against the envelope in
[cpu-capture-baseline.md](../../docs/performance/cpu-capture-baseline.md).
