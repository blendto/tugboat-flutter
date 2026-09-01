# Tugboat Flutter

Flutter SDK for capturing session evidence for Tugboat.
The Tugboat CLI is maintained separately; this repository contains only Flutter and
Dart packages.

**Repository:** [github.com/blendto/tugboat-flutter](https://github.com/blendto/tugboat-flutter)

## Packages

- [`tugboat`](packages/tugboat) — the Flutter SDK, published on [pub.dev](https://pub.dev/packages/tugboat)
- [`tugboat_dio`](packages/tugboat_dio) — optional Dio adapter, published on [pub.dev](https://pub.dev/packages/tugboat_dio)
- [`tugboat/example`](packages/tugboat/example) — demo app and integration fixture (not a separate pub.dev package)

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
