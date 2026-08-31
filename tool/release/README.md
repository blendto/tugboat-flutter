# Unpublished Android experimental artifacts

Public publication is **blocked**. Device privacy rows and Phase 7 performance
gates have not passed. Do not:

- tag `capture-runtime-v0.1.0` or `flutter-v0.9.0`
- publish `com.tugboat.sdk:capture-runtime` to Maven Central
- publish `package:tugboat` `0.9.0` to pub.dev
- make `nativeCpuExperimental` the default

Keep `TugboatScreenshotCaptureBackend.flutterRepaintBoundary` in production.
The 0.8.12 adapter may consume `capture-runtime` `0.1.0` from untracked
`.local-maven` after `bash tool/ci/build-android-runtime.sh`.

When gates pass, follow [process.md](../../docs/releases/process.md).

To checksum a local AAR (not a release artifact):

```sh
bash tool/ci/build-android-runtime.sh
sha256sum .local-maven/com/tugboat/sdk/capture-runtime/0.1.0/*.aar
```

Do not commit `.local-maven/` or treat those hashes as the signed release.
