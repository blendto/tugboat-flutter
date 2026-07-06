# Tugboat Flutter

Flutter SDK for capturing session evidence and generating stable widget catalogs.
The Tugboat CLI is maintained separately; this repository contains only Flutter and
Dart packages.

**Repository:** [github.com/blendto/tugboat-flutter](https://github.com/blendto/tugboat-flutter)

## Packages

- [`tugboat`](packages/tugboat) — the Flutter SDK
- [`tugboat_builder`](packages/tugboat_builder) — optional build-time widget catalog generator
- [`tugboat/example`](packages/tugboat/example) — demo app and integration fixture (not published)

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
dart run melos run test:builder
dart run melos run test:sdk
```

Regenerate the example widget catalog:

```sh
dart run melos run generate:example
git diff -- packages/tugboat/example/lib/tugboat_widgets.g.dart
```

`tugboat_widgets.g.dart` is generated but intentionally committed as an integration
fixture. Do not edit it manually.

## Workspace conventions

- Run dependency commands from the repository root. The workspace has one shared
  `pubspec.lock`; package-level lockfiles should not be committed.
- Public SDK imports use `package:tugboat/tugboat.dart`.
- Builder configuration uses the key `tugboat_builder|widget_catalog`.
- Keep package versions and changelogs independent.

## License

[GNU Affero General Public License v3.0](LICENSE)
