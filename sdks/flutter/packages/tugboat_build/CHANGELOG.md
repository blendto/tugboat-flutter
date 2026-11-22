## 0.1.0

### Added

- First version: a `build_runner` builder that writes
  `lib/tugboat_widget_names.g.dart`, a `const Map<Type, String>` from every
  public, concrete, non-generic Flutter widget class in the package's `lib/` to
  its source class name, for `TugboatReplayConfig.widgetNames`.
- Private, generic, abstract and sealed widgets are skipped; private and
  generic ones are recorded in a comment in the generated file.
- `variable_name` and `exclude` builder options.
- Requires `analyzer` 8.0 through 14.x (`build` 3.0.1 through 5.x). Analyzer 7
  is excluded: it cannot parse the dot shorthands in current Flutter SDK
  sources. The element model is read dynamically, under member names shared by
  analyzer 8.0 through 14.x, so the builder follows the host's analyzer. The
  tests run against analyzer 8.4.1; host builds were run by hand with Flutter
  3.35.7 (analyzer 8.0.0, 8.4.1 and 10.0.1) and Flutter 3.47.5 (analyzer 8.4.1
  and 14.7.0).
- Fails the build when every library fails to scan or the analyzer lacks a
  member the scanner reads (`build_runner` then removes the generated file
  until the next successful build), and warns loudly when the generated map is
  empty.
- Rejects a `variable_name` that is a reserved word, private, looks like a
  generated import prefix (`_i0`), or shadows a `dart:core` type the generated
  file uses (`Map`, `String`, `Type`).
- Not published to pub.dev yet.
