# Tugboat Flutter

Flutter packages for capturing Tugboat session evidence and generating stable
widget catalogs.

## Packages

- [`tugboat`](packages/tugboat): the Flutter SDK.
- [`tugboat_builder`](packages/tugboat_builder): the optional build-time widget
  catalog generator.

The repository uses a Dart pub workspace for local package resolution and
Melos for repository-wide commands.

```sh
dart pub get
dart run melos run analyze
dart run melos run test
```
