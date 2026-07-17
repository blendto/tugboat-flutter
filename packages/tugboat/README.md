# Tugboat Flutter SDK

Screenshot-based session evidence for Tugboat. The SDK records masked visual
checkpoints around meaningful interactions, compact structural anchors, route
transitions, scrolling evidence, and optional viewport semantic maps. Capture
can be sent to the local exploration WebSocket, the HTTP collector, or both.

The current package version is `0.2.0`. Session JSON uses schema version `7`
(readers still accept `6`), and structural fingerprints use fingerprint schema
version `6`.

## Install

Add `tugboat` to the host app and import the public barrel:

```dart
import 'package:tugboat/tugboat.dart';
```

The package requires Dart 3.9.2 or newer and Flutter 3.35.0 or newer.

## Minimal integration

Install both the app wrapper and navigator observer. Capture is dormant by
default, so choose an active profile when the app should record immediately:

```dart
MaterialApp(
  navigatorObservers: [TugboatReplay.navigatorObserver],
  builder: (context, child) => TugboatReplay.wrapApp(
    child: child!,
    config: const TugboatReplayConfig(
      profile: TugboatCaptureProfile.exploration,
      explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
      viewportSemanticMode: TugboatViewportSemanticMode.full,
    ),
  ),
);
```

Without `TugboatReplay.navigatorObserver`, pointer and scroll capture still
work, but route-change events and route-backed anchors are incomplete. Without
`wrapApp`, no capture controller, repaint boundary, or input/scroll listener is
installed.

## Capture profiles and runtime state

`TugboatReplayConfig.profile` controls whether the wrapper installs capture
machinery:

| Profile | Current behavior | Default screenshot masking |
| --- | --- | --- |
| `dormant` | Lightweight gate mounted; no capture machinery until `activate` | explicit subtrees only, if activated |
| `exploration` | full interaction capture, scene inventories, optional emitted semantic maps | `TugboatSensitive` only |
| `productionLean` | interaction capture and sampled/deduplicated screenshots; no scene-inventory events | all text, editable fields, and images |

The global kill switch is fully inert:

```dart
TugboatReplay.disabled = true; // deactivates and disposes the active controller
```

Dormant builds can be activated at runtime without rebuilding `MaterialApp`:

```dart
TugboatReplay.activate(
  activationRequestId: captureRequestId,
  profile: TugboatCaptureProfile.productionLean,
);
```

Identity contract:

- `activationRequestId` — host orchestration / request correlation
- `captureSessionId` (`session.id`) — SDK-generated emitted evidence session
- `collectorSessionId` — stamped after HTTP `session_start` acceptance
- `explorationRunId` — exploration control-plane ID from config

`TugboatReplay.activeSessionId` remains as a deprecated alias for
`activationRequestId`. Inspect `TugboatReplay.health` for sink/outbox/screenshot
budget pressure without reading protected content.

Optional durable HTTP delivery (Collector only, default off):

```dart
TugboatReplayConfig(
  profile: TugboatCaptureProfile.productionLean,
  collector: collectorConfig,
  outbox: TugboatOutboxConfig(enabled: true),
);
```

Call `TugboatReplay.clearDurableOutbox()` on logout/consent revocation.

## Configuration reference

`TugboatReplayConfig` currently exposes:

| Field | Default | Purpose |
| --- | --- | --- |
| `profile` | `dormant` | capture cost and exploration-only behavior |
| `settleDelay` | 1 second | delay before post-interaction and post-route capture |
| `maxFrames` | 500 | in-memory frame bound |
| `maxEvents` | 5000 | in-memory event bound |
| `scrollCaptureInterval` | 2 seconds | interval for scroll checkpoint capture |
| `captureScrollSamples` | `false` | retain `TugboatScrollSample` records in session JSON |
| `capturePixelRatio` | `0.75` | repaint-boundary screenshot scale |
| `enableGlobalPointerCapture` | `true` | use global pointer routing; `false` uses a local `Listener` |
| `explorationCollectorUrl` | null | local exploration WebSocket endpoint |
| `explorationRunId` | null | optional run correlation ID |
| `userId` | null | optional HTTP event user ID |
| `appInfo` | null | app metadata used by exploration and as a fallback |
| `collector` | null | HTTP collector configuration |
| `screenshotMaskLevel` | profile default | explicit screenshot redaction policy |
| `widgetNames` | empty | `Type` to stable-name overrides for canonical paths |
| `viewportSemanticMode` | `tapResolutionOnly` | semantic engine and emission mode |
| `viewportSemanticMapMaxNodes` | 120 | emitted map node budget |
| `viewportSemanticMapMaxBytes` | 48000 | emitted map byte budget |

## Privacy and payload boundary

Use `TugboatSensitive` for content that must always be hidden in screenshots:

```dart
TugboatSensitive(
  child: Text('Do not show in replay'),
)
```

Available mask levels are `explicitOnly`, `allTextAndMedia`, `allText`,
`allTextExceptActionable`, `sensitiveInputsOnly`, and `nonAssetImagesOnly`
(masks non-asset `Image` widgets — such as `Image.network`, `Image.file`, and
`Image.memory` — plus sensitive inputs, while bundled asset graphics and text
stay visible; other custom-painted or decorated image surfaces are not
classified by this mode, so wrap them in `TugboatSensitive` when needed).

The structural telemetry does not retain arbitrary `Text`, accessibility,
tooltip, or icon label strings. Dynamic list discriminators are hashed before
they enter canonical paths. Telemetry does include developer-authored routing
and identity strings where applicable:

- route names in `route_change.data` and anchor `routeKey` fields;
- `TugboatSubView.label` in state/scroll context;
- `TugboatTag.id` in `targetAnchor.fingerprintParts.tag` (and its hashed
  `tagFingerprint`);
- widget type names and canonical structural paths;
- normalized bounds, pointer coordinates, scroll metrics, and screenshot
  pixels after the configured masking policy is applied.

Screenshots are the only captured surface that can contain rendered user
content. Choose an explicit production masking policy and test custom widgets,
platform views, and overlays in the target app before enabling production
capture.

## Event and frame model

The controller maintains an in-memory `TugboatSession` and fans new evidence
out to configured sinks. Sink failures are isolated from the host app. The
session is bounded by `maxFrames` and `maxEvents`; trimming marks it
`truncated`.

Emitted event types currently include:

- lifecycle: `session_start`, `session_end`;
- input: `tap`, `tap_settled`, `swipe`, `pointer_cancel`,
  `tap_outside_tree`;
- state/navigation: `state_change`, `route_change`;
- scrolling: `scroll_start`, `scroll_end`;
- exploration: `scene_inventory`, `action_window_set`,
  `action_window_cleared`;
- semantic-map modes: `viewport_semantic_map`,
  `scroll_semantic_snapshot`.

Frames can be triggered by initial startup, taps, scrolls, routes, lifecycle,
or explicit controller calls. Capture requests are serialized and coalesced.
The SDK first skips repeated state signatures, then uses a small dHash to avoid
PNG encoding for visually unchanged content, and finally deduplicates encoded
frames by content hash.

During local WebSocket exploration, connecting without an HTTP collector
suppresses new Flutter screenshot capture for UI-thread performance. Events,
anchors, inventories, and semantic evidence continue to stream; the CLI's ADB
before/after screenshots remain the primary gesture-level visual evidence.

## Structural identity

Fingerprint schema v6 derives target identity from route plus a normalized
canonical widget path. Wrapper widgets are filtered, same-type siblings receive
ordinals, list positions collapse to `[item]`, and conservative static list
discriminators are hashed. `TugboatTag` adds an alias without changing the
structural fingerprint:

```dart
TugboatTag(
  'checkout-submit',
  child: FilledButton(onPressed: submit, child: const Text('Submit')),
)
```

`TugboatSubView` adds a developer-owned section label useful for nested content
and scroll attribution. `widgetNames` can replace runtime type names used in
canonical paths, which is particularly useful when an obfuscated build needs a
generated stable-name map.

State signatures in v6 are deliberately coarse: route key plus keyboard,
modal, and subview state. Role counts remain diagnostic metadata but do not
determine the signature. Identity should be joined only within the same build
and fingerprint schema version.

## Lifecycle

- A session starts after the wrapped repaint boundary has a non-zero viewport.
- `paused` or `hidden` schedules a sink flush after 500 ms; resuming cancels a
  pending flush.
- `detached` ends the session.
- Removing the wrapper or deactivating disposes the controller, emits
  `session_end`, and asks configured sinks to finish asynchronously.
- The HTTP sink also flushes partial batches on its timer and before session
  end.

## Public surface

The supported import exports `TugboatReplay`, `TugboatNavigatorObserver`,
`TugboatReplayConfig`, capture/semantic/masking enums and policies, collector
configuration and host helpers, markers (`TugboatSensitive`, `TugboatTag`,
`TugboatSubView`, `TugboatInternal`), anchor and session models, the controller,
and `TugboatExplorationTransport`.

`TugboatCaptureSink` and the built-in sink implementations are internal today;
config supports only the WebSocket and HTTP destinations above. A stable custom
sink registration API has not been published.

## Current limits

- Platform views, maps, video textures, and native overlays may be absent or
  incomplete in repaint-boundary screenshots and structural walks.
- Screenshot readback and PNG encoding perform UI-thread work at checkpoints.
- Runtime activation/deactivation requires a host rebuild, and activation IDs
  are not yet the emitted session IDs.
- There is no automatic Android intent-extra/deep-link bridge, offline file
  sink, durable on-device retry store, or public custom-sink API.
- HTTP retry queues are bounded and in-memory only. Process death loses pending
  output.
- Nested navigator and anonymous-route identity depends on structural fallback
  and needs app-specific validation.
- The package captures no logs, network traffic, analytics events, or native
  performance signals.

See [Collector integration](../../docs/integration/collector.md) and
[Capture and fingerprint status](../../docs/design/capture-and-fingerprint.md)
for transport details, implementation evidence, and prioritized next work.
