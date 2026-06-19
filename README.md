# PMKit Flutter

Flutter packages for capturing PMKit session evidence and generating stable
widget catalogs.

## Packages

- [`pmkit`](packages/pmkit): the Flutter SDK.
- [`pmkit_builder`](packages/pmkit_builder): the optional build-time widget
  catalog generator.

The repository uses a Dart pub workspace for local package resolution and
Melos for repository-wide commands.

```sh
dart pub get
dart run melos run analyze
dart run melos run test
```
