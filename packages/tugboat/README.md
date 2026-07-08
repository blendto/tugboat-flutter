# Tugboat Flutter SDK

Screenshot-based session replay for Tugboat. The SDK captures masked screenshot
checkpoints around meaningful interactions, plus compact interaction anchors
(hit-test target, state signature, and route transitions), then streams the raw evidence to the
Tugboat collector.

This follows the Tugboat ideation architecture: visual evidence frames +
lightweight interaction telemetry, not widget-tree scene reconstruction.

## Usage

```dart
MaterialApp(
  navigatorObservers: [TugboatReplay.navigatorObserver],
  builder: (context, child) => TugboatReplay.wrapApp(
    child: child!,
    config: const TugboatReplayConfig(
      profile: TugboatCaptureProfile.exploration,
      viewportSemanticMode: TugboatViewportSemanticMode.full,
    ),
  ),
);
```

Use `TugboatSensitive` when a subtree must always be masked in screenshots:

```dart
TugboatSensitive(
  child: Text('Do not show in replay'),
)
```

Masking defaults follow the capture profile: `exploration` masks only explicit
`TugboatSensitive` subtrees, while `productionLean` masks all text, editable
fields, and images. Override this with `TugboatReplayConfig.screenshotMaskLevel`.

Optional `TugboatReplayConfig.widgetNames` can override runtime type names used
in canonical paths (useful for obfuscated builds); supply the map by hand.

## Architecture

The SDK has three capture pipelines that share a frame-scoped widget walk:

```text
pointer / route / scroll
        │
        ▼
┌───────────────────┐
│  AnchorResolver   │  single token-map walk per frame (cached)
│  scene inventory  │
└─────────┬─────────┘
          │
          ├── screenshots (RepaintBoundary → engine PNG, dHash thumbnail)
          └── viewport semantic map (Flutter Semantics, exploration-heavy)
          │
          ▼
     capture sinks (WS exploration / HTTP collector)
```

Performance notes:

- Token maps are reused within a Flutter frame across tap, state, inventory, and
  mask-rect collection.
- Screenshot encoding uses the engine PNG encoder (no Dart isolate / `image`
  package on the hot path). dHash is computed from a 9×8 downscale so unchanged
  frames skip PNG work.
- A persistent `SemanticsHandle` is held only in the exploration profile;
  production tap resolution avoids permanent semantics cost.

## Collector integration

The SDK can stream capture output to:

- the local CLI exploration collector over WebSocket
- the standalone HTTP collector (`tugboat-collector`) with batched REST ingestion

See [Collector integration](../../docs/integration/collector.md) for setup
details, including the default event batch size of `10`.

## Capture model

- **Evidence plane:** PNG screenshots at checkpoints (initial, before/after tap,
  optional scroll samples, route changes), deduplicated by content hash and
  perceptual hash. During CLI exploration, captured frames are streamed over the
  WebSocket when produced; the recorder persists them under `frames/`.
- **Interaction plane:** tap events with target and state anchors, route changes
  in event `data`, scroll/swipe events with scrollable anchors, and
  `beforeFrame` / `afterFrame` references. Text, accessibility, tooltip, and
  icon labels are not retained in telemetry.
- **Scroll/swipe attribution:** `scroll_start` / `scroll_end` include the
  resolved scrollable `targetAnchor` plus axis, depth, edge/overscroll, section
  label, and offset metrics in `data`. Pointer drags beyond touch slop emit a
  `swipe` event instead of a normal `tap_settled`; `data.scrolled:false` marks a
  dead swipe / failed scroll intent.
- **Scene inventory (exploration):** per settled screen state, the SDK enumerates
  interactive controls and persists them via the CLI sink as `inventories/<stateSignature>.json`.
  Entries include fingerprints, canonical paths, roles, and aliases. Tap injection guarantees
  exploration taps join their inventory even when the element was not center-probed.
- **Attribution diagnostics (CLI exploration):** `action_window_set` /
  `action_window_cleared` (recorder action-window lifecycle), `tap_outside_tree`
  (pointer down with no hit-test target), and `pointer_cancel` (gesture cancelled
  before up).
- **Settle delay:** default 1s after taps and route transitions before capture
- **Profiles:** `dormant` (default, zero overhead until `TugboatReplay.activate`),
  `exploration`, `productionLean`
- **Fingerprint schema:** v6 uses coarse state identity (route + overlay flags +
  subLabel). Optional `TugboatReplayConfig.widgetNames` can override runtime type
  names used in canonical paths (useful for obfuscated builds); supply the map by hand.

## Current limits

- Platform views, maps, and native overlays are not captured faithfully
- Screenshot capture can cause brief UI-thread work at checkpoints
- Sessions remain in memory and are streamed to the configured collector
- The host app must install the wrapper and navigator observer
