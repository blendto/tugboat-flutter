# Tugboat mobile

Mobile capture SDKs for Tugboat. This repository is becoming a monorepo
(`core/`, `platforms/`, `sdks/`). The GitHub remote is still
[blendto/tugboat-flutter](https://github.com/blendto/tugboat-flutter) until
the rename to `tugboat-mobile` is applied.

The Tugboat CLI is maintained separately.

## Flutter packages

- [`tugboat`](sdks/flutter/packages/tugboat) — the Flutter SDK
- [`tugboat_dio`](sdks/flutter/packages/tugboat_dio) — Dio network evidence
- [`tugboat/example`](sdks/flutter/packages/tugboat/example) — demo app (not published)

Native Android and Apple runtimes and the C++ core land in later phases.

## Documentation

See [docs/](docs/README.md) for integration guides and design notes.

## Requirements

- Flutter 3.35.0 or newer
- Dart 3.9.2 or newer
- Git

The repository uses a native Dart pub workspace for local package resolution and
Melos 7 for shared development commands.

## Setup

From the repository root:

```sh
dart pub get
dart run melos list
dart run melos run analyze
```

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

## Workspace conventions

- Run dependency commands from the repository root. The workspace has one shared
  `pubspec.lock`; package-level lockfiles should not be committed.
- Public SDK imports use `package:tugboat/tugboat.dart`.
- Keep package versions and changelogs independent.

## License

[GNU Affero General Public License v3.0](LICENSE)
