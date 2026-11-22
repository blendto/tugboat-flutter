## 0.1.0

### Added

- First version: a `build_runner` builder that writes
  `lib/tugboat_widget_names.g.dart`, a `const Map<Type, String>` from every
  public, concrete, non-generic Flutter widget class in the package's `lib/` to
  its source class name, for `TugboatReplayConfig.widgetNames`.
- Private, generic, abstract and sealed widgets are skipped; private and
  generic ones are recorded in a comment in the generated file.
- `variable_name` and `exclude` builder options.
- Reads the analyzer's element model through a small compatibility layer, so it
  allows the `analyzer` 7.x through 14.x that `build` 3 to 5 allow. The tests in
  this repository run only against analyzer 7.7.1; the analyzer 8 and newer
  path was checked by building scratch hosts by hand (analyzer 8, 10 and 14),
  not by automated tests.
- Fails the build when every library fails to scan or the analyzer lacks a
  member the scanner reads (`build_runner` then removes the generated file
  until the next successful build), and warns loudly when the generated map is
  empty.
- Rejects a `variable_name` that is a reserved word, private, or looks like a
  generated import prefix (`_i0`).
- Not published to pub.dev yet.
