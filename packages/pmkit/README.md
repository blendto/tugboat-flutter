# PMKit Flutter SDK

Screenshot-based session replay for PMKit. The SDK captures masked screenshot
checkpoints around meaningful interactions, plus compact interaction anchors
(hit-test target, state signature, and route transitions), then streams the raw evidence to the
PMKit collector.

This follows the PMKit ideation architecture: visual evidence frames +
lightweight interaction telemetry, not widget-tree scene reconstruction.

## Usage

```dart
MaterialApp(
  navigatorObservers: [PmkitReplay.navigatorObserver],
  builder: (context, child) => PmkitReplay.wrapApp(
    child: child!,
    config: const PmkitReplayConfig(),
  ),
);
```

Use `PmkitSensitive` when a subtree must always be masked in screenshots:

```dart
PmkitSensitive(
  child: Text('Do not show in replay'),
)
```

Masking defaults follow the capture profile: `exploration` masks only explicit
`PmkitSensitive` subtrees, while `productionLean` masks all text, editable
fields, and images. Override this with `PmkitReplayConfig.screenshotMaskLevel`.

## Collector integration

The SDK can stream capture output to:

- the local CLI exploration collector over WebSocket
- the standalone HTTP collector (`pmkit-collector`) with batched REST ingestion

See [docs/collector-integration.md](docs/collector-integration.md) for setup
details, including the default event batch size of `10`.

## Optional widget catalog

`pmkit_builder` can preserve public source-level widget names in canonical paths,
including in obfuscated builds. Add `pmkit_builder` and `build_runner` as dev
dependencies, run `dart run build_runner build`, then pass the generated map:

```dart
import 'pmkit_widgets.g.dart';

PmkitReplay.wrapApp(
  config: const PmkitReplayConfig(widgetNames: pmkitWidgetNames),
  child: child,
)
```

The generator is optional. Without it, PMKit continues to use runtime type
names. Exploration and production must use the same catalog configuration for
their fingerprints to match.

## Capture model

- **Evidence plane:** PNG screenshots at checkpoints (initial, before/after tap,
  optional scroll samples, route changes), deduplicated by content hash and
  perceptual hash
- **Interaction plane:** tap events with target and state anchors, route changes
  in event `data`, and `beforeFrame` / `afterFrame` references. Text,
  accessibility, tooltip, and icon labels are not retained in telemetry.
- **Settle delay:** default 1s after taps and route transitions before capture
- **Profiles:** `dormant` (default, zero overhead until `PmkitReplay.activate`),
  `exploration`, `productionLean`
- **Fingerprint schema:** v4 uses fresh visibility-aware trees, filters blocked
  modal routes, and supports generated widget names. Schema-v3 evidence remains
  readable but must not be joined directly with v4 fingerprints.

## Current limits

- Platform views, maps, and native overlays are not captured faithfully
- Screenshot capture can cause brief UI-thread work at checkpoints
- Sessions remain in memory and are streamed to the configured collector
- The host app must install the wrapper and navigator observer
