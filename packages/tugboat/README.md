# Tugboat Flutter SDK

Screenshot-based session evidence for Tugboat. The SDK records masked visual
checkpoints around meaningful interactions, compact structural anchors, route
transitions, scrolling evidence, and optional viewport semantic maps. Capture
can be sent to the local exploration WebSocket, the HTTP collector, or both.

The current package version is `0.5.1`. Session JSON writers emit schema
version `9`; compatibility readers should accept versions `6` through
`9`. Structural fingerprints use fingerprint schema version `6`.

## Install

Add `tugboat` to the host app and import the public barrel:

```dart
import 'package:tugboat/tugboat.dart';
```

The package requires Dart 3.9.2 or newer and Flutter 3.35.0 or newer.

## Migrating to 0.5.0

This is a breaking release. Session JSON written by 0.5.0 uses schema version
`9` and no longer includes `controlValue`, `controlValueTransition`, or
`semanticAnnotation` in event `data`. Consumers reading historical schemas
`6`–`8` should treat those fields as optional historic data; new captures do
not provide them.

The public `package:tugboat/tugboat.dart` barrel no longer exports:

- `TugboatEncodedControlScalar`, `TugboatVisibleControlValue`,
  `TugboatControlValueScope`, `TugboatControlValue`, and
  `TugboatSemanticAnnotation`;
- `tugboatControlValueSchemaVersion`,
  `tugboatControlValueTransitionSchemaVersion`, and
  `tugboatSemanticAnnotationSchemaVersion`;
- `tugboatControlValueForWidget`,
  `tugboatControlValueFromSemanticsProperties`,
  `tugboatControlValueFromSemanticsNode`,
  `tugboatSemanticAnnotationFromProperties`,
  `tugboatSemanticAnnotationFromNode`,
  `tugboatMergeSemanticAnnotations`, and `tugboatMergeControlValues`.

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
work, but route-change events and route-backed anchors are incomplete. Nested
Navigators that must be attributed need their own observer instance:

```dart
Navigator(
  observers: [TugboatReplay.createNavigatorObserver()],
  // ...
);
```

Without `wrapApp`, no capture controller, repaint boundary, or input/scroll listener is
installed.

### Navigation and overlays

The supplied observer is intended to record standard Navigator `push`, `pop`,
`replace`, and `remove` callbacks without application code calling the replay
controller for each navigation. Dialog and modal-bottom-sheet routes can
participate when they use that observed Navigator. Nested navigators need their
own observer wiring, and native/system overlays are outside the Flutter
Navigator/repaint-boundary contract.

Each visible route change creates a route epoch and waits for the transition
plus the configured settle delay before taking the destination capture. A newer
visible route supersedes an older pending capture. Consequently, a route event
and a related `tap_settled` event are intended to reference a frame compatible
with that route epoch, or report bounded degraded/capture diagnostics rather
than attach an origin-route frame merely because it was the latest frame.

This is an implemented SDK invariant, not a production-accepted guarantee.
Production acceptance for #13/#14 remains open: rapid or nested modal chains
and programmatic/automatic navigation can still be absent or degraded. Treat
those cases as an SDK capture gap, not as coherent replay evidence.

### Deferred taps and interaction claims

`tap` is sampled at pointer-down but emitted only after gesture classification
(or when a claimed `route_change` must publish a cause). Consumers must read:

| Field | Meaning |
| --- | --- |
| `data.replayRole` | `interaction` (real user tap) or `causal_only` (cause id for a route; not a replayable action) |
| `data.gestureFinal` | `tap`, `swipe`, `cancelled`, `superseded`, `session_end`, or `unresolved` |
| `data.sampledAtMs` | Pointer-down sample time when the event was published later |
| `data.captureCoordinate` | Boundary-local / normalized / raster transform for the before-frame |
| `route_change.data.navigationOrigin` | `interaction` or `automatic_or_unknown` |
| `route_change.data.causeEventId` | Claimed tap id when origin is `interaction` |
| `route_change.data.interactionAttribution` | Always `same_turn` when claimed |
| `swipe`/`pointer_cancel.data.invalidatesRelatedTap` | Boolean `true` when a related causal tap should be ignored for playback |
| `tap_gesture_resolved` | Promotes `relatedEventId` from `causal_only` → interaction (`promotesRelatedTap`) |

Released pointer-up claims attribute a route only through the pointer-up turn
(sync `onTap` → `Navigator.push`). Timer/auth redirects after that turn stay
`automatic_or_unknown`. Backgrounding and `session_end` drop pending claims
without minting orphan `causal_only` taps for cancelled routes.

**Downstream contract:** Context Graph and PMKit CLI must not treat
`replayRole: causal_only` taps as real actions or step openers.

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
- `traitsId` — collector-issued traits dictionary id after `setTraits` / session responses

`TugboatReplay.activeSessionId` remains as a deprecated alias for
`activationRequestId`. Inspect `TugboatReplay.health` for sink/outbox/screenshot
budget pressure without reading protected content.

### User traits and user id

When an HTTP collector is configured, register a full traits snapshot (not a
partial merge) via `POST /v1/sessions`:

```dart
await TugboatReplay.setTraits({
  'plan': 'pro',
  'seatCount': 3,
});

await TugboatReplay.setUserId(currentUserId);
```

- `setTraits` sends `eventType: traits_updated` with the full bag when a capture
  session is active, caches the response `traitsId`, and stamps that id onto
  subsequent event batches.
- `setUserId` sends `eventType: user_changed` (with the cached traits bag when
  set) and updates the runtime user id on later sessions/events. Calls with the
  same id as the current runtime user are ignored (no `user_changed` post).
- Pre-activate calls are retained in memory and included on the next
  `session_start`. There is no `/v1/identify` route.

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
| `interactionClaimWindow` | 1,250 ms | released-tap window for delayed route/modal attribution; `Duration.zero` keeps microtask-only same-turn claims |
| `interactionPublishMode` | `dualWrite` | how finalized gestures are published: `legacyOnly`, `dualWrite` (canonical + legacy peers on `stream: legacy_projection`), or `canonicalOnly` |
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
| `sinkFactories` | empty | extra `TugboatCaptureSinkFactory` adapters |
| `outbox` | disabled | durable HTTP outbox configuration |
| `screenshotBudget` | defaults | degraded-capture skip window / budget |

### Resolver and exploration events

When exploration is active, the controller may emit:

| Event | Role |
| --- | --- |
| `scene_inventory` | Deduped actionable/image inventory for the settled state |
| `viewport_semantic_map` | Bounded semantic node map (mode-dependent) |
| `scroll_semantic_snapshot` | Semantic snapshot tied to scroll checkpoints |
| `action_window_set` / `action_window_cleared` | CLI exploration action-window fencing |
| `tap_outside_tree` | Pointer resolved no target; carries the same `replayRole` / `gestureFinal` as the paired tap when deferred |
| `tap_gesture_resolved` | Promotes a prior `causal_only` tap (`promotesRelatedTap: true`, `relatedEventId`) after the gesture finalizes as a real tap |

Consumers that filter `replayRole: causal_only` must honor `tap_gesture_resolved` (or the patched in-memory tap) before suppressing genuine navigations.

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

- canonical: `interaction` (`stream: semantic`) — one finalized gesture with
  immutable `origin`, `result`, `attribution`, and `evidenceEventIds`;
- legacy gesture peers (`stream: legacy_projection` when canonical is on):
  `tap`, `tap_settled`, `swipe`, `tap_outside_tree`, `tap_gesture_resolved`;
- lifecycle: `session_start`, `session_end`;
- input: `pointer_cancel` (`stream: evidence`);
- state/navigation evidence (`stream: evidence`): `state_change`, `route_change`
  (claimed routes also carry `causedByInteractionId`);
- scrolling evidence (`stream: evidence`): `scroll_start`, `scroll_end`;
- diagnostics: `capture_diagnostic` (`stream: diagnostic`);
- exploration: `scene_inventory`, `action_window_set`,
  `action_window_cleared`;
- semantic-map modes: `viewport_semantic_map`,
  `scroll_semantic_snapshot`.

Default enrichment and insight selection should use `stream: semantic`
`interaction` records (`enrichmentCandidate: true` on collector payloads).
Rage-tap style insights must count finalized `gesture=tap` interactions with
no successful `navigated`/`changed` result; exclude scrolls, swipes,
cancellations, evidence, legacy projections, and diagnostics.

Frames can be triggered by initial startup, taps, scrolls, routes, lifecycle,
or explicit controller calls. Capture requests are serialized and coalesced.
The SDK first skips repeated state signatures, then uses a small dHash to avoid
PNG encoding for visually unchanged content, and finally deduplicates encoded
frames by content hash.

Pointer coordinates in event data (`x`, `y`, and swipe `startX`/`startY`) are
Flutter global logical-pixel coordinates from the pointer event. The SDK
converts a copy into its capture boundary's local space only for hit-testing and
normalizing target/viewport-semantic bounds; stored event coordinates are not
capture-boundary-normalized for replay playback. Do not interpret them as
physical pixels or as coordinates relative to an individual widget. Fractional
overlay drift is therefore still possible.

For a tap, origin context (`stateAnchor`, target, `beforeFrame`,
`captureCoordinate`, route/navigator identity) is frozen at pointer-down into
an `InteractionTransaction`. After pointer-up, settlement waits for either the
first eligible visible successor inside `interactionClaimWindow` (default
1,250 ms) or the deadline. The canonical `interaction` event retains that
frozen origin and attaches destination/result fields when a successor claims.
Legacy `tap` + `tap_settled` remain dual-written for migration; `tap_settled`
links via `relatedEventId` / `interactionId`. A missing attachment is explicit
in `frameAttachment`/settle diagnostics rather than a fallback to an unrelated
frame.

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

## Capture diagnostics

Each logical capture request emits exactly one privacy-safe
`capture_diagnostic` event and contributes to the bounded, session-scoped
`healthSnapshot().captureDiagnostics` counter. Distinct request IDs with the
same execution ID (and `coalesced: true`) identify scheduler coalescing.
Diagnostics contain only bounded correlation, outcome, route epoch, trigger,
and evidence fields; they never include image bytes, labels, raw errors, or
stack traces. `visualEvidence` distinguishes fresh, reused, and unavailable
visual evidence, while `interactionEvidence` states whether the request links
to an interaction event. The closed outcome vocabulary is:

| Outcome | Meaning |
| --- | --- |
| `fresh_accepted` | A fresh frame was accepted. |
| `exact_content_reused` | An exact content hash reused a compatible frame. |
| `perceptual_hash_coalesced` | A perceptual hash reused a compatible frame. |
| `state_signature_short_circuit` | Compatible semantic state made capture unnecessary. |
| `screenshot_budget_skip` | Degraded screenshot budget skipped eligible work. |
| `superseded_route_epoch` | Navigation superseded the request's route epoch. |
| `paint_readiness_timeout` | A fresh paint did not become available in time. |
| `boundary_unavailable` | The repaint boundary was detached, replaced, or unpainted. |
| `capture_processing_failed` | Readback, masking, or encoding failed. |
| `cancelled` | The session/controller was cancelled. |
| `no_compatible_frame` | No frame was safe to attach to the request context. |
| `no_frame_available` | No frame has been captured for the request context. |

Cancellation diagnostics add one bounded reason such as `dispose`,
`session_end`, `session_replacement`, or `lifecycle_deactivate`. The counter
caps both total values and distinct outcome keys and resets for each session,
so it is suitable for health polling and cannot grow with session duration.

## Public surface

The supported import exports `TugboatReplay` (including `setTraits` /
`setUserId`), `TugboatNavigatorObserver`, `TugboatReplayConfig`,
capture/semantic/masking enums and policies, collector configuration and host
helpers, markers (`TugboatSensitive`, `TugboatTag`, `TugboatSubView`,
`TugboatInternal`), anchor and session models, the controller, and
`TugboatExplorationTransport`.

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
