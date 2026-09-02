# Android runtime release notes

`com.gettugboat.sdk:capture-runtime` publishes from GitHub Actions on tag
`capture-runtime-v<version>`. See [process.md](../../docs/releases/process.md).

Do not:

- make `nativeCpuExperimental` the default until privacy and performance
  gates pass
- point the Flutter plugin at GitHub Packages (pub.dev hosts cannot auth)
- publish Apple `TugboatCaptureRuntime` `0.1.0`

Keep `TugboatScreenshotCaptureBackend.flutterRepaintBoundary` in production.
Flutter `0.8.14` depends on Maven Central
`com.gettugboat.sdk:capture-runtime:0.1.0`. Local Maven (`.local-maven` after
`bash tool/ci/build-android-runtime.sh`) is only for the standalone native
Android sample.

To checksum a local AAR (not a signed Central artifact):

```sh
bash tool/ci/build-android-runtime.sh
version="$(bash tool/ci/android-runtime-version.sh)"
shasum -a 256 ".local-maven/com/gettugboat/sdk/capture-runtime/${version}"/*.aar
```

Do not commit `.local-maven/` or treat those hashes as the signed release.
