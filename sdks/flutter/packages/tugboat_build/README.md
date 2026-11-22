# tugboat_build

`build_runner` generator for the Tugboat SDK's `widgetNames` map.

Tugboat names widgets in canonical paths with `widget.runtimeType.toString()`.
A Flutter release build compiled with `--obfuscate` mangles those strings, so
the SDK cannot tell `CheckoutScreen` from any other class. `tugboat_build` scans
your app's `lib/` at build time and writes a `const Map<Type, String>` of your
widget classes to their readable source names. Pass it to
`TugboatReplayConfig.widgetNames` and those classes keep their names in the
SDK's canonical paths and recorded widget types after obfuscation.

This package is not published to pub.dev yet (`publish_to: none`). Use it from
a checkout or a git dependency.

## What it covers, and what it does not

Read this before relying on it. The generator names **public, concrete,
non-generic widget classes declared in your package's `lib/`**. It cannot name:

- **Private widgets** (`_CheckoutBody`). A class whose name starts with `_` is
  visible only inside its own library, so the generated file cannot refer to
  it. The SDK falls back to whatever `runtimeType.toString()` returns for such a
  widget, which in an obfuscated build is not a stable name across builds.
  (Without obfuscation the SDK leaves private widgets out of canonical paths.)
  To get a stable name for a private widget, make the class public.
- **Generic widgets** (`class Picker<T> extends StatelessWidget`). The SDK looks
  names up by exact `runtimeType`, and `Picker<int>` and `Picker<String>` are
  different types. A raw `Picker` key would only match the one instantiation
  that Dart infers for it, so the generator leaves generic widgets out and lists
  them in a comment in the generated file.
- **Abstract and sealed widgets.** They are never instantiated, so they never
  appear as a `runtimeType`.
- **Widgets from other packages**, including Flutter's own (`Scaffold`, `Text`,
  `InkWell`, ...) and widgets from your path or monorepo packages. The map only
  covers the package that runs the builder. Framework and third-party widgets
  keep whatever `runtimeType.toString()` returns, so the SDK's built-in matching
  on their names (for example its sliver and wrapper handling) depends on that
  string being the real class name. A generated map makes your own widgets
  readable and stable; it does not make an obfuscated build equivalent to an
  unobfuscated one.
- **Name-based features that read `runtimeType.toString()` directly.** The map
  feeds canonical paths and the recorded widget type. The SDK's placeholder
  detection (`Shimmer`, `Skeleton`, `Placeholder`, `Redacted` in a type name),
  its `Sliver` list-container check, its check for private widgets while it
  resolves a sheet or dialog, and its route-type matching (sheet, dialog and
  menu kinds) do not consult the map. Where the type name is mangled they stop
  matching, for your widgets as well as the framework's.
- `State` classes. They are not widgets and never appear as `widget.runtimeType`
  (the widgets that own them are covered).

Names are deterministic for one source tree. Renaming a class changes its name
in canonical paths, like any other identity input.

## Setup

1. Add the generator and `build_runner` as development dependencies.

   ```yaml
   dev_dependencies:
     build_runner: ^2.7.1
     tugboat_build:
       git:
         url: https://github.com/blendto/tugboat-flutter
         path: sdks/flutter/packages/tugboat_build
   ```

   `tugboat_build` requires `analyzer` 8.0 through 14.x and `build` 3.0.1
   through 5.x. Analyzer 7 cannot parse the dot shorthands in current Flutter
   SDK sources (the build fails with `Missing implementation of
   visitDotShorthandPropertyAccess`), so the package excludes it; if your
   resolution fails on `analyzer`, upgrade `build_runner` or whatever pins
   analyzer 7. Flutter 3.35 (Dart 3.9) can resolve up to analyzer 10.

   It reads the analyzer's element model dynamically, under member names that
   are the same in analyzer 8.0 through 14.x, so it follows whichever analyzer
   your `build_runner` brings. Tested end to end by building a host app:

   | Flutter | `build_runner` | `build` | `analyzer` |
   | --- | --- | --- | --- |
   | 3.35.7 | 2.7.1 | 3.1.0 | 8.0.0, 8.4.1 |
   | 3.35.7 | 2.15.1 | 4.0.7 | 10.0.1 |
   | 3.47.5 | 2.15.1 | 4.0.7 | 8.4.1 (this repository's example app) |
   | 3.47.5 | 2.17.1 | 5.0.0 | 14.7.0 |

   The tests in this repository run against the analyzer the workspace
   lockfile resolves (8.4.1). `build_runner` 2.7.0 or newer is needed so a
   fresh checkout that already contains the committed output builds without
   `--delete-conflicting-outputs`; 2.7.1 is the oldest tested.

2. Generate the map.

   ```sh
   dart run build_runner build
   ```

   This writes `lib/tugboat_widget_names.g.dart`. Commit it, so release builds
   do not depend on running `build_runner`. Re-run the command when you add,
   rename, or remove a widget.

3. Pass the map to the SDK.

   ```dart
   import 'package:tugboat/tugboat.dart';

   import 'tugboat_widget_names.g.dart';

   MaterialApp(
     navigatorObservers: [TugboatReplay.navigatorObserver],
     builder: (context, child) => TugboatReplay.wrapApp(
       child: child!,
       config: const TugboatReplayConfig(
         enabled: true,
         widgetNames: tugboatWidgetNames,
       ),
     ),
   );
   ```

   If you derive the config with `copyWith`, pass `widgetNames:
   tugboatWidgetNames` there.

The generated file imports every library that declares a public widget. A
library that does not compile for your mobile targets (for example one that
imports `dart:html`) breaks the build when it is imported; exclude it.

## Options

Set them in the host's `build.yaml`.

```yaml
targets:
  $default:
    builders:
      tugboat_build:tugboat_widget_names:
        options:
          variable_name: appWidgetNames   # default: tugboatWidgetNames
          exclude:                        # globs relative to the package root
            - lib/web/**
```

An unknown option or a malformed value fails the build. The output path is
fixed at `lib/tugboat_widget_names.g.dart`.

## Verify

- The builder fails with a clear error when every library fails to scan or the
  analyzer lacks a member it needs; it never writes an empty map in that case.
  `build_runner` then removes the generated file until the next successful
  build, so code that imports it fails to compile, loudly. If you commit the
  file, fix the error and rebuild. When the scan works but finds no widget to
  name, the builder still writes an empty map and logs a warning that says the
  map is EMPTY; treat that as a failure to investigate, not as success.
- Open the generated file. Each named widget is one `ClassName: 'ClassName'`
  entry. A comment at the top counts the private widgets that were skipped and
  lists the generic ones.
- Keep it fresh in CI: run `dart run build_runner build` and fail if
  `git diff --exit-code lib/tugboat_widget_names.g.dart` reports a change.
- Check the screens you care about with a test, so a missing widget fails
  before release:

  ```dart
  test('checkout screen is named', () {
    expect(tugboatWidgetNames[CheckoutScreen], 'CheckoutScreen');
  });
  ```

- Confirm on a real obfuscated build
  (`flutter build apk --obfuscate --split-debug-info=build/symbols`): the path
  segments for your own public widgets should carry the readable names from the
  map. Do not expect the whole path to equal a debug build's. Framework wrapper
  widgets, and every other name-based match listed above, are not covered by
  the map and can still appear under mangled names.
