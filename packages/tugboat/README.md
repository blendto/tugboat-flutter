# Tugboat Flutter SDK

Screenshot-based session evidence for Tugboat. The SDK records masked visual
checkpoints around meaningful interactions, compact structural anchors, route
transitions, scrolling evidence, and optional viewport semantic maps. Capture
can be sent to the local exploration WebSocket, the HTTP collector, or both.

The current package version is `0.8.10`. Session JSON writers and readers use
schema version `10` only. Structural fingerprints use fingerprint schema
version `6`.

## 0.8.10

Viewport semantic capture reads Flutter's last stable semantics tree. It no
longer forces a semantics flush while layout can be dirty. Inventory fallback
covers nodes that Flutter has not committed yet. Release-gate screenshot tests
now wait for controller capture work instead of a fixed delay. Collector
contract coverage includes pan and both zoom directions.

## 0.8.9

Pinch and pan stay in one interaction until all contacts lift. Replacement
fingers preserve the gesture and cumulative zoom scale. Pinches can start with
contacts closer than the touch slop. Trackpad pan includes its travel in
`endPosition` and `delta`. Stationary third-finger taps remain taps until
movement confirms a shared gesture. Travel continues after the primary finger
lifts. Pause, hide, and detach clear old input contacts. One-finger canvas pan
remains `swipe`.

## 0.8.8

Exploration capture now snapshots fresh target, inventory, and viewport
semantic evidence at primary pointer-down. Completed taps reuse this evidence,
including the original route facts. Missing targets include a closed failure
reason. Guarded inventory fallback can identify an unlinked actionable semantic
node with low confidence.

## 0.8.7

`TugboatCollectorHost.fromPlatform()` snapshots optional session-start device
facts on `session_start`: battery percentage, free internal storage, Android
physical RAM, and active network type. Each field is omitted when unavailable.

Three-finger shared translation now publishes one canonical `swipe` with
`payload.pointerCount: 3`. Two-finger pan/zoom and one-finger swipe are
unchanged. OS-owned system gestures that never reach Flutter are not recorded.

## 0.8.6

Default `TugboatReplay.eventHook` parameter policy now retains bounded
JSON-safe values, including in production capture profiles. Pass
`TugboatParameterPolicy.namesOnly` to keep keys without values.

Canonical interactions now include `pan`, `zoom_in`, and `zoom_out` for
two-pointer pinch/translation and trackpad pan/zoom. Nested payload adds
`pointerCount` and, for zoom, `scale`. Tap, swipe, and scroll are unchanged.

`productionLean` profiles no longer emit `capture_diagnostic` events to the
session or collector. On-device `healthSnapshot().captureDiagnostics` counters
still update. Exploration profiles still emit full diagnostic events.

## 0.8.5 release compatibility

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.5`. It
removes deprecated public APIs, so deploy the coordinated collector compatibility
update before you release the SDK.

New writers omit `stateAnchor`, `stateSignature`, and `state_change` events.
The old public state model types are removed. Each completed tap, swipe, and
scroll records a temporal after-frame when capture succeeds. The collector
mapper also omits the
top-level `stateAnchor` key. Deploy the related collector change with this SDK
release.

Schema-v2 collector events (`interaction`, `route_change`) are flat facts-only
records: no nested top-level `payload` on route changes, no empty
`targetAnchor`, and no inferred interaction `result`. Interaction v2 uses a
nested `payload` for gesture facts (`tap`/`swipe`/`scroll`/`pan`/`zoom_in`/`zoom_out`/`cancelled`) and
no longer emits separate `scroll_start`, `scroll_end`, or `pointer_cancel`
events.

## Install

Add `tugboat` to the host app and import the public barrel:

```dart
import 'package:tugboat/tugboat.dart';
```

The package requires Dart 3.9.2 or newer and Flutter 3.35.0 or newer.

### Optional Dio network evidence

```yaml
dependencies:
  tugboat_dio: ^0.8.10
```

See `packages/tugboat_dio/README.md`.

## Coded events and network observation

Opt-in coded-event hooks append to the active session without coupling to Amplitude,
Firebase, or a specific HTTP client:

```dart
final appEvents = TugboatReplay.eventHook(
  source: 'analytics',
  parameterPolicy: TugboatParameterPolicy.allowList({'method', 'result'}),
);
appEvents.record('USER_LOGIN', parameters: {'method': 'email'});

final call = TugboatReplay.beginNetworkCall(
  method: 'GET',
  route: '/blend/RC-T4KE7', // bounded absolute path; dynamic IDs are allowed
);
call.complete(statusCode: 200);

// HTTP error bodies may be supplied as bounded JSON/text evidence.
final failedCall = TugboatReplay.beginNetworkCall(
  method: 'POST',
  route: '/projects',
);
failedCall.complete(
  statusCode: 422,
  errorResponseBody: {'code': 'invalid_project'},
);
```

Both emit on `stream: evidence` and never inherit exploration `actionId` or UI
anchors. The default parameter policy retains JSON-safe values within hard
limits in every capture profile, including production. `allowAll` is an
exploration-only escape hatch; outside exploration profiles the SDK downgrades
it to names-only at record time.

### Omitting parameter values

Use `namesOnly` when the host must retain parameter keys without values:

```dart
final privateEvents = TugboatReplay.eventHook(
  source: 'analytics',
  parameterPolicy: TugboatParameterPolicy.namesOnly,
);
privateEvents.record(
  'SEARCH',
  parameters: {'query': 'chicken soup'},
);
```

The default policy can retain feedback, search terms, URLs, IDs, and other user
content. Hosts that need a narrower set can pass an allow-list or a transform.
The SDK still deep-copies JSON-safe values and applies its hard JSON and size
bounds.

Network routes must be bounded absolute paths. Dynamic identifier segments are
allowed. The SDK drops resolver output containing a scheme, query, fragment,
percent-encoded data, a network-path prefix, backslash, or whitespace/control
characters. Route paths can contain user or tenant identifiers. Hosts must
apply their own privacy and retention policy.
HTTP response bodies are retained only when `statusCode >= 400`. JSON and text
are deep-copied and bounded to 16 KiB; binary and unsupported values are
omitted. Successful response bodies are never retained.

Hooks resolve the active controller when `record` is called, rather than keeping
a session reference. Network tokens are bound to the capture session in which
they were created. Finishing a token after `clear`, session replacement,
deactivation, or session end is a bounded no-op and cannot append evidence to a
newer session. Calls made while Tugboat is dormant, disabled, deactivating, not
yet started, or already ended are also safe no-ops.

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
and a related canonical `interaction` are intended to reference a frame compatible
with that route epoch, or report bounded degraded/capture diagnostics rather
than attach an origin-route frame merely because it was the latest frame.

This is an implemented SDK invariant, not a production-accepted guarantee.
Production acceptance for #13/#14 remains open: rapid or nested modal chains
and programmatic/automatic navigation can still be absent or degraded. Treat
those cases as an SDK capture gap, not as coherent replay evidence.

### Interaction claims

Pointer-down freezes interaction origin data. Pointer-up classifies the gesture
and publishes one canonical `interaction`. A claimed `route_change` uses that
interaction ID as `causeEventId`. Released pointer-up claims apply only through
the pointer-up turn. Timer or auth redirects stay `automatic_or_unknown`.

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

Inspect `TugboatReplay.health` for sink and screenshot-budget pressure
without reading protected content.

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

- `setTraits` debounces `traits_updated` (3s) after start acceptance, or
  `session_identify` when combined with a pending user change. Caches
  `traitsId` and stamps it on event batches. While `session_start` is pending,
  updates memory only (folded into start at send time).
- `setUserId` debounces `user_changed` (3s) after start acceptance, or
  `session_identify` when combined with a pending traits change. Unchanged ids
  are ignored. While `session_start` is pending, updates memory only.
- Pre-activate calls are retained in memory and included on the next
  `session_start` when present. Pending debounced updates flush on `session_end`.
  There is no `/v1/identify` route.

Collector delivery is best-effort. The SDK keeps bounded in-memory retry queues,
but it does not persist events or frames across process restarts.

## Configuration reference

`TugboatReplayConfig` currently exposes:

| Field | Default | Purpose |
| --- | --- | --- |
| `profile` | `dormant` | capture cost and exploration-only behavior |
| `settleDelay` | 1 second | delay before post-interaction and post-route capture |
| `scrollEndCaptureDelay` | zero | optional idle delay before a pointer-linked scroll after-frame; does not block the controller queue |
| `interactionClaimWindow` | 1,250 ms | released-tap window for delayed route/modal attribution; `Duration.zero` keeps microtask-only same-turn claims |
| `maxFrames` | 500 | in-memory frame bound |
| `maxEvents` | 5000 | in-memory event bound |
| `scrollCaptureInterval` | 2 seconds | interval for scroll metric sampling and optional semantic/in-motion visual checkpoints |
| `captureScrollSamples` | `false` | retain `TugboatScrollSample` records in session JSON |
| `captureScrollScreenshots` | `false` | request pressure-droppable visual checkpoints while scrolling; scroll metrics and the scroll-end observation remain independent |
| `capturePixelRatio` | `0.75` | requested repaint-boundary screenshot scale; values above `1.0` are supported |
| `captureMaxWidth` / `captureMaxHeight` | null | optional output pixel bounds applied before readback while preserving aspect ratio |
| `degradedCaptureScale` | `0.67` | additional scale applied before readback while the screenshot budget is degraded |
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
| `screenshotBudget` | 60ms / 5s window | degraded-capture skip window / budget |

### Resolver and exploration events

When exploration is active, the controller may emit:

| Event | Role |
| --- | --- |
| `scene_inventory` | Deduped actionable/image inventory for the settled state |
| `viewport_semantic_map` | Bounded semantic node map (mode-dependent) |
| `scroll_semantic_snapshot` | Semantic snapshot tied to scroll checkpoints |
| `action_window_set` / `action_window_cleared` | CLI exploration action-window fencing |

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

The structural telemetry does not use or retain arbitrary `Text`,
accessibility, tooltip, or icon label strings as target identity. List and grid
items use structural positions. Telemetry does include developer-authored
routing and identity strings where applicable:

- route names in `route_change.data` and anchor `routeKey` fields;
- `TugboatSubView.label` in state/scroll context;
- `TugboatTag.id` in `targetAnchor.fingerprintParts.tag` (and its hashed
  `tagFingerprint`);
- widget type names and canonical structural paths;
- active app locale language, country, script, and BCP 47 tag when available;
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

**Inferred events** are derived from UI instrumentation. **Coded events** are
host-supplied analytics records via `TugboatReplay.eventHook` (see
[Coded events and network observation](#coded-events-and-network-observation)).

Emitted inferred event types currently include:

- canonical: `interaction` (`stream: semantic`) — one finalized gesture
  (`tap`, `swipe`, `scroll`, `pan`, `zoom_in`, `zoom_out`, or `cancelled`) with
  gesture-specific facts under `payload` (omitted for `cancelled`);
- lifecycle: `session_start`, `session_identify`, `session_end`;
- navigation evidence (`stream: evidence`): `route_change`;
- diagnostics: `capture_diagnostic` (`stream: diagnostic`; exploration profiles only;
  `productionLean` updates on-device health counters without session events);
- exploration: `scene_inventory`, `action_window_set`,
  `action_window_cleared`;
- semantic-map modes: `viewport_semantic_map`,
  `scroll_semantic_snapshot`.

Pinch and pan records keep `eventType: interaction`. Read the `gesture` field
to identify the movement:

| Observed movement | `gesture` |
| --- | --- |
| Fingers move apart, or trackpad scale increases | `zoom_in` |
| Fingers move together, or trackpad scale decreases | `zoom_out` |
| Two fingers move together in one direction, or trackpad pan | `pan` |
| Three or more fingers move together in one direction | `swipe` |
| Drag with an observed Flutter scroll | `scroll` |
| Single-finger drag without an observed Flutter scroll | `swipe` |

Classification requires movement above the gesture threshold. A classified
touch gesture ends when all contacts lift. A replacement finger joins the
active gesture. The payload includes `pointerCount` for multiple contacts
and `scale` for zoom. Single-finger canvas pan intentionally records `swipe`.
Observed Flutter scrolling remains `scroll`.

Touch travel follows the primary contact while that contact is down. After it
lifts, `endPosition` continues from its last point using movement of the active
contacts' centroid. Contact joins and lifts do not add travel by themselves.
Touch `scale` is the cumulative ratio of contact spans across contact changes.
It is not a measurement of the host widget's transform or proof of a visible
resize.

Default enrichment and insight selection should use inferred events:
`stream: semantic` `interaction` records (`enrichmentCandidate: true` on
collector payloads).
Rage-tap style insights must count finalized `gesture=tap` interactions;
exclude scrolls, swipes, cancellations, evidence, and
diagnostics.

Frames can be triggered by initial startup, interactions, routes, lifecycle,
or explicit controller calls. Capture requests are serialized. Non-interaction
requests can coalesce. When the capture boundary has not painted since the
last accepted frame, the SDK reuses that frame without GPU readback. Otherwise
it uses a small dHash (Hamming distance ≤ 2) to avoid JPEG encoding for
near-identical content, and finally deduplicates encoded frames by content hash.
Each completed tap, swipe, scroll, pan, and zoom requests a post-interaction
observation.
An already encoded route frame can satisfy that observation even when route
causality is unknown. The frame records only what was visible later. It does
not prove that the interaction caused the observed UI or navigation.

A new pointer-down cancels a pending deferred scroll-end screenshot before the
next `ScrollStart`. The prior scroll keeps its final metrics and interaction
record, but it does not attach a stale frame or block the new gesture. The SDK
also delays tap-only target, scene-inventory, and viewport-semantic resolution
until pointer-up, so scroll gestures do not perform tap analysis on their
input-critical path.

Interaction payload coordinates use normalized capture-boundary space. Do not
interpret them as physical pixels or as coordinates relative to a widget.

For a tap, origin context (target, `beforeFrame`,
`captureCoordinate`, route/navigator identity) is frozen at pointer-down into
an `InteractionTransaction`. After pointer-up, settlement waits for either the
first eligible visible successor inside `interactionClaimWindow` (default
1,250 ms) or the deadline. The canonical `interaction` event retains that
frozen origin. Route ownership remains separate. `afterFrame` is only a later
visual observation and can come from an unclaimed route successor. It does not
assign a result or destination to the interaction.

During local WebSocket exploration, connecting without an HTTP collector
suppresses only non-interaction Flutter screenshot capture for UI-thread
performance. Every completed interaction still requests a post-interaction
visual observation. A route capture can satisfy it. Events, anchors, inventories,
and semantic evidence continue to stream; the CLI's ADB before/after screenshots
remain the primary gesture-level visual evidence.

## Structural identity

Fingerprint schema v6 derives target identity from route plus a normalized
canonical widget path. Wrapper widgets are filtered, same-type siblings receive
ordinals, and list or grid items receive structural `[item:index]` tokens.
`TugboatTag` adds an alias without changing the structural fingerprint:

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

Locale is evidence, not identity. When `wrapApp` is installed in
`MaterialApp.builder` or `CupertinoApp.builder`, the SDK observes the active
`Localizations` locale. Session metadata and every event carry the current
locale. A change emits a `locale_changed` evidence event with the previous and
current locale. Exploration WebSocket sessions carry the same locale metadata.

Apps that mount Tugboat above `Localizations`, or own a separate locale state,
can report it explicitly:

```dart
TugboatReplay.setLocale(const Locale('es', 'ES'));
```

Atlas can use the locale tag to select locale-specific enrichment. It must keep
build identity and target fingerprint as the control identity key.

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

Each logical capture request records one privacy-safe resolution in
`healthSnapshot().captureDiagnostics` (bounded outcome counts and last
outcome). Exploration profiles also emit a `capture_diagnostic` session event
(`stream: diagnostic`). `productionLean` profiles omit those events from the
session and collector to reduce volume; use on-device health for capture
telemetry in production.

Distinct request IDs with the same execution ID (and `coalesced: true`) identify
scheduler coalescing when diagnostic events are present. Diagnostics contain only
bounded correlation, outcome, route epoch, trigger, and evidence fields; they
never include image bytes, labels, raw errors, or stack traces. `visualEvidence` distinguishes fresh, reused, and unavailable
visual evidence, while `interactionEvidence` states whether the request links
to an inferred event. The closed outcome vocabulary is:

| Outcome | Meaning |
| --- | --- |
| `fresh_accepted` | A fresh frame was accepted. |
| `exact_content_reused` | An exact content hash reused a compatible frame. |
| `perceptual_hash_coalesced` | A perceptual hash reused a compatible frame. |
| `paint_generation_unchanged` | The capture subtree had not painted since the last accepted frame. |
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
- Screenshot readback and JPEG encoding perform UI-thread and background-isolate
  work at checkpoints.
- Runtime activation/deactivation requires a host rebuild, and activation IDs
  are not yet the emitted session IDs.
- There is no automatic Android intent-extra/deep-link bridge, offline file
  sink, durable on-device retry store, or public custom-sink API.
- HTTP retry queues are bounded and in-memory only. Process death loses pending
  output.
- Nested navigator and anonymous-route identity depends on structural fallback
  and needs app-specific validation.
- The package captures no logs or native performance signals. It supports
  opt-in external events and network observations with the privacy boundaries
  described above.

See [Collector integration](../../docs/integration/collector.md) and
[Capture and fingerprint status](../../docs/design/capture-and-fingerprint.md)
for transport details, implementation evidence, and prioritized next work.
