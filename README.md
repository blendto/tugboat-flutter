# Tugboat mobile

Mobile capture SDKs for Tugboat. This repository is a mobile monorepo:
a portable C++ image core, native capture runtimes, and framework adapters.

The GitHub remote is still
[blendto/tugboat-flutter](https://github.com/blendto/tugboat-flutter) until an
administrator renames it to `tugboat-mobile`. See
[repository migration](docs/releases/repository-migration.md).

The Tugboat CLI is maintained separately.

## Layout

| Path | Product |
| --- | --- |
| `core/image-processing` | Portable C++ CPU core (C ABI) |
| `platforms/android` | `com.tugboat.sdk:capture-runtime` AAR |
| `platforms/apple` | Apple runtime (`TugboatCaptureRuntime` 0.1.0, unpublished) |
| `sdks/flutter/packages/tugboat` | Flutter adapter / plugin ([pub.dev](https://pub.dev/packages/tugboat)) |
| `sdks/flutter/packages/tugboat_dio` | Dio network evidence ([pub.dev](https://pub.dev/packages/tugboat_dio)) |
| `sdks/flutter/packages/tugboat/example` | Demo app (not published) |
| `sdks/react-native` | Future adapter placeholder |
| `docs/` | Architecture, integration, privacy, performance, releases |
| `tool/ci` | Host test, generate, and release-control scripts |

Do not copy the C++ core into the published pub package. In this monorepo the
Flutter plugin compiles Android and Apple runtimes from `platforms/` (and
`core/`) when those trees resolve. Published pub consumers get a stub HostApi
that reports unsupported native capture and keep the default Flutter backend.

## Capture backends

`package:tugboat` still defaults to Flutter `RepaintBoundary` screenshots.
Android native CPU capture is an experimental opt-in
(`TugboatScreenshotCaptureBackend.nativeCpuExperimental`). iOS uses the
same opt-in flag for a live Flutter-layer CPU path. Both stay experimental
until privacy device rows and
[native capture contracts](docs/architecture/native-capture-contracts.md) plus
the [experimental native CPU](docs/integration/native-cpu-experimental.md)
gates pass. Raw pixels never enter Dart. See
[experimental native CPU capture](docs/integration/native-cpu-experimental.md).

## Requirements

- Flutter 3.35.0 or newer
- Dart 3.9.2 or newer
- Android NDK `28.2.13676358` and CMake `3.22.1` to build the AAR
- Git

The repository uses a native Dart pub workspace for local package resolution and
Melos 7 for shared development commands.

## Setup

From the repository root:

```sh
dart pub get
dart run melos list
bash tool/ci/run-image-core-tests.sh
bash tool/ci/build-android-runtime.sh
bash tool/ci/run-flutter-tests.sh
```

Native Android apps consume the AAR from untracked `.local-maven/` after
`bash tool/ci/build-android-runtime.sh`, or from GitHub Packages after a
`capture-runtime-v*` tag. The Flutter plugin compiles
`platforms/android/capture-runtime` from source in the monorepo.

## Development

```sh
dart run melos run format
dart run melos run analyze
dart run melos run test
```

Package-specific tests:

```sh
dart run melos run test:sdk
```

Public SDK imports use `package:tugboat/tugboat.dart`. Keep package versions
and changelogs independent. Run dependency commands from the repository root;
the workspace has one shared `pubspec.lock`.

## Documentation

See [docs/](docs/README.md) for public architecture, integration, privacy, and
release process. Working notes are not product docs; see
[docs/publishing.md](docs/publishing.md).

## License

[GNU Affero General Public License v3.0](LICENSE)
