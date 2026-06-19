# Tugboat Build

Optional build-time widget catalog generation for `tugboat`.

Add `tugboat_builder` and `build_runner` to the application's dev dependencies,
then run:

```sh
dart run build_runner build
```

The default output is `lib/tugboat_widgets.g.dart` with a constant named
`tugboatWidgetNames`. Pass it to `TugboatReplayConfig.widgetNames`.

The builder scans `lib` by default. It can be configured in the consuming
application's `build.yaml`:

```yaml
targets:
  $default:
    builders:
      tugboat_builder|widget_catalog:
        options:
          output_path: lib/generated/tugboat_widgets.g.dart
          scan_directories: [lib, packages/ui/lib]
          variable_name: appWidgetNames
```

Private widgets are excluded because generated libraries cannot legally import
private Dart declarations. Framework base widgets and generated Dart files are
also excluded.
