# Tooling

- `benchmarks/` — device-lab capture protocol (Phase 7; not CI)
- `ci/run-flutter-tests.sh` — Flutter package tests
- `ci/run-image-core-tests.sh` — C++ core tests with ASan/UBSan
- `ci/build-android-runtime.sh` — Android AAR tests, release build, local Maven, sample
- `ci/android-runtime-version.sh` — print `capture-runtime` `VERSION_NAME`
- `ci/generate-native-capture-pigeon.sh` / `verify-native-capture-pigeon.sh`
- `ci/check-version-policy.sh` — path-aware Flutter/runtime/compatibility bumps
- `ci/check-license.sh` — AGPL-3.0-only
- `ci/dump-android-runtime-api.py` / `verify-android-runtime-api.sh`
- `ci/verify-swift-api.sh` — public Swift API dump vs `platforms/apple/api.txt`
- `ci/pub-dry-run.sh` — `dart pub publish --dry-run` for Flutter packages
- `release/` — Android runtime release notes; tags `capture-runtime-v*` publish the AAR
