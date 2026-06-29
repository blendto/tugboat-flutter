# PMKit Flutter

Flutter packages for capturing PMKit session evidence and generating stable
widget catalogs. The PMKit CLI is intentionally maintained separately; this
repository contains only Flutter and Dart packages.

## Packages

- [`pmkit`](packages/pmkit): the Flutter SDK.
- [`pmkit_builder`](packages/pmkit_builder): the optional build-time widget
  catalog generator.
- [`pmkit_example`](packages/pmkit/example): an example and integration fixture
  for both packages. It is not published.

## Requirements

- Flutter 3.35.0 or newer
- Dart 3.9.2 or newer
- Git

The repository uses a native Dart pub workspace for local package resolution
and Melos 7 for shared development commands.

## Setup

From the repository root, install all workspace dependencies:

```sh
dart pub get
```

Melos is already a development dependency, so a global installation is not
required. Run it through Dart:

```sh
dart run melos list
dart run melos run analyze
```

If you prefer the shorter `melos` command, install it globally and ensure the
pub cache executable directory is on your `PATH`:

```sh
dart pub global activate melos
melos list
```

Use the version constrained in the root `pubspec.yaml` when global and local
Melos behavior differs.

## Development

Format and analyze the complete workspace before committing:

```sh
dart run melos run format
dart run melos run analyze
```

Run all package tests:

```sh
dart run melos run test
```

During focused development, run only the affected package:

```sh
dart run melos run test:builder
dart run melos run test:sdk
```

The underlying commands also work directly:

```sh
dart test packages/pmkit_builder/test
flutter test packages/pmkit
```

## Testing Changes

For SDK changes:

1. Add or update tests under `packages/pmkit/test`.
2. Run `dart run melos run test:sdk`.
3. Run the example from `packages/pmkit/example` when behavior is visible or
   requires real navigation, screenshots, or masking.

For builder changes:

1. Add or update tests under `packages/pmkit_builder/test`.
2. Run `dart run melos run test:builder`.
3. Regenerate the example catalog and inspect the result:

```sh
dart run melos run generate:example
git diff -- packages/pmkit/example/lib/pmkit_widgets.g.dart
```

`pmkit_widgets.g.dart` is generated but intentionally committed because it is
also an integration fixture. Do not edit it manually.

## Workspace Conventions

- Run dependency commands from the repository root. The workspace has one
  shared `pubspec.lock`; package-level lockfiles should not be committed.
- Workspace packages depend on each other with normal version constraints, not
  relative path dependencies. Pub resolves matching workspace members locally.
- Public SDK imports use `package:pmkit/pmkit.dart`.
- Builder imports and configuration use `pmkit_builder`, including the builder
  key `pmkit_builder|widget_catalog`.
- Keep package versions and changelogs independent. A change to one package does
  not automatically require releasing the other.
- Update the example whenever a public API or builder output changes.

## Before Publishing

- Replace the placeholder SDK `LICENSE` with the chosen project license and add
  a license to `pmkit_builder`.
- Update the relevant package version and `CHANGELOG.md`.
- Run formatting, analysis, package tests, and the example builder integration.
- Run `dart pub publish --dry-run` from the package directory being released.
- Confirm package metadata such as repository and issue-tracker URLs before the
  first pub.dev release.
