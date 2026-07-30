# Capture and fingerprint architecture

Status: current implementation audit (2026-07-26)
Scope: `packages/tugboat` in this repository

This document describes what the Flutter SDK implements today. It deliberately
does not specify the internals of the CLI, collector, dashboard, or Atlas
services. Those systems consume the contracts described here, but their own
repositories remain authoritative for ingestion and enrichment behavior.

## Goals and invariants

The SDK captures evidence that can be joined to an app graph without retaining
arbitrary visible text as structural identity.

- State and target identity are deterministic within one build and fingerprint
  schema version.
- Exploration and production profiles use the same fingerprint algorithm.
- Developer tags strengthen matching but are optional.
- Screenshots remain visual evidence and are masked before leaving the app.
- Capture failures and sink failures must not interrupt the host app.
- Dormant and disabled modes return the host child unchanged.

Cross-build stability is not promised. Consumers should namespace identity by
build metadata and `fingerprintSchemaVersion`; remapping identities across app
builds is downstream work.

## Current architecture

```text
NavigatorObserver + global/local pointer input + scroll notifications
                              |
                              v
                 TugboatReplayController
                    |        |        |
                    |        |        +-- viewport semantic session
                    |        +----------- masked screenshot capturer
                    +-------------------- structural anchor resolver
                              |
                        in-memory session
                              |
                    sink hub (failure-isolated)
                       /                  \
              exploration WebSocket    HTTP collector
```

`TugboatReplay.wrapApp` installs the controller, repaint boundary, input
capture, scroll listener, and lifecycle observer only for an active profile.
`TugboatReplay.navigatorObserver` supplies route changes and navigator context.
Both are needed for complete capture.

### Profiles and activation

| Profile | Implemented behavior |
| --- | --- |
| `dormant` | Always-mounted lightweight gate; no pointer/screenshot/sink machinery until `activate` |
| `exploration` | full interaction capture, scene inventory, and optional emitted semantic maps |
| `productionLean` | interaction capture, no scene-inventory events, production screenshot masking by default |

`TugboatReplay.disabled = true` is a global kill switch. It deactivates the
current controller and keeps future calls to `wrapApp` inert. Runtime
`activate(activationRequestId:, profile:)` notifies the mounted gate without
requiring a host rebuild. `deactivate()` tears capture down through the same
gate. Pause/hidden flush pending delivery; detach ends the session once.

Identity fields (session schema **v7**; readers accept v6):

- `activationRequestId` — host request correlation
- `captureSessionId` — SDK-emitted session (`session.id`)
- `collectorSessionId` — HTTP transport ID after accept
- `explorationRunId` — exploration control plane

Cross-build fingerprint equivalence remains outside this repository. The SDK
emits exact build and fingerprint-schema provenance only.

## Session and event model

The controller owns one bounded, in-memory `TugboatSession`. Serialized session
JSON is schema version `7`. Readers accept schema versions `6` and `7`.

The session stores:

- frame metadata plus PNG bytes;
- ordered events;
- optional scroll samples;
- app/platform/viewport metadata;
- activation / capture / collector identity fields;
- a `truncated` flag when configured frame or event limits are exceeded.

Optional opt-in durable outbox (Collector HTTP only) persists sanitized
delivery envelopes across process restarts within byte/age bounds.

The event stream currently includes:

- lifecycle: `session_start`, `session_end`;
- pointer intent and outcome: `tap`, `tap_settled`, `swipe`,
  `pointer_cancel`, `tap_outside_tree`;
- navigation and state: `route_change`, `state_change`;
- scrolling: `scroll_start`, `scroll_end`;
- exploration control: `scene_inventory`, `action_window_set`,
  `action_window_cleared`;
- optional semantic evidence: `viewport_semantic_map`,
  `scroll_semantic_snapshot`.

Events may carry `beforeFrame`, `afterFrame`, `stateAnchor`, `targetAnchor`,
`relatedEventId`, `explorationRunId`, `actionId`, an interaction result, and
type-specific `data`. Route transition values live in `route_change.data`, not
in a session-level route dictionary.

### Capture lifecycle and attribution

`wrapApp` starts a session only after its repaint boundary has a non-zero
viewport. The session begins with `session_start` and an initial capture
request. Pointer-down records `tap` plus a compatible pre-interaction frame,
then pointer-up either records a swipe or creates one `tap_settled` outcome.
The settled event refers to the initial tap through `relatedEventId` and is
intended to attach an after-frame only when that frame's provenance matches the
observed route epoch. A capture that is unavailable, cancelled, superseded, or
timed out is represented by bounded capture/attachment diagnostics instead of
borrowing the latest frame from another screen.

Frame requests are serialized, may coalesce, and use fresh-paint/readback
checks before publishing. Their provenance records the capture context and
completion state, so exact-content and perceptual deduplication reuse frames
only within a compatible context. `paused` and `hidden` request a delivery
flush after 500 ms; `resumed` cancels that pending flush; `detached`, wrapper
disposal, and deactivation end the session once and initiate sink shutdown.

Input event coordinates (`x`, `y`, and swipe start/delta values) originate as
Flutter global logical-pixel coordinates. The resolver converts a global point
to capture-boundary local coordinates only to hit-test and normalize it against
the viewport; stored coordinates are not capture-boundary-normalized for replay
playback, are neither device pixels nor widget-local, and can therefore produce
fractional overlay drift.

### Navigator and modal routes

Installing `TugboatReplay.navigatorObserver` is intended to record the standard
Navigator push, pop, replace, and remove callbacks automatically. No
per-navigation SDK call is required. Dialogs and `showModalBottomSheet`
instances can participate when their routes use that observed Navigator. Nested
navigators require their own observer integration; native/system overlays
remain outside the Flutter Navigator and repaint-boundary surface.

Every visible navigation change advances a route epoch and has a single route
capture barrier after transition settlement. A later visible navigation
supersedes stale work. This is the implemented intended invariant: a delayed
destination capture or tap-settle operation should not attach the prior route's
frame, and an unavailable compatible frame should remain explicitly degraded.

It is not yet a production-accepted guarantee. Production acceptance #13/#14
remains open: rapid/nested modal chains and programmatic/automatic navigation
can still be absent or degraded. Treat those observations as SDK capture gaps,
not as coherent replay evidence.

Pointer work and post-interaction capture are serialized through a controller
queue. An error in one queued task is caught and logged so later taps, scrolls,
and route captures continue.

## Fingerprint schema v6

`tugboatFingerprintSchemaVersion` is currently `6`. Hashes are 16-character
SHA-256 prefixes derived from sorted identity parts.

### Canonical target identity

The SDK does not hash the raw Flutter element tree. `AnchorResolver` builds a
frame-scoped token map that:

1. excludes SDK chrome, hidden/offstage/zero-opacity nodes, excluded semantics,
   and content obscured by a blocking overlay;
2. removes a versioned denylist of layout, styling, animation, navigation,
   state-management, and scroll-plumbing wrappers;
3. retains salient and actionable widgets, including actionable widgets such
   as `InkWell` even when their type is otherwise denylisted;
4. assigns same-type sibling ordinals after filtering;
5. collapses repeating list positions to `[item]` while preserving a hashed,
   conservative static discriminator when available;
6. resolves a route key from a non-anonymous route name or a structural
   fallback;
7. caches the token map only for the current Flutter frame so tap resolution,
   state identity, inventories, and screenshot masking can reuse one walk.

A target fingerprint is derived from `routeKey + canonicalPath`. The serialized
`TugboatTargetAnchor` retains the canonical path, widget type, role, normalized
position metadata, enabled/actions metadata, confidence, and compact
fingerprint parts for diagnosis.

`TugboatTag` and a stable `ValueKey<String>` can add a high-confidence
`tagFingerprint`. A tag is transparent to structural identity: adding it does
not change the target fingerprint or state signature. `TugboatSubView` adds a
developer-owned subview label for route-internal state and scroll attribution.

### State identity

Schema v6 deliberately uses coarse state identity. `stateSignature` hashes:

- `routeKey`;
- keyboard-open state;
- modal-open state;
- the active `TugboatSubView.label`, when present;
- the fingerprint schema version during computation.

Actionable role counts are emitted as diagnostic `actionableSummary` metadata
but do not determine the signature. Dynamic list length, visible rows, and
control multiplicity therefore do not fork a screen state.

The schema version is also serialized beside the hash. Downstream joins must
include build identity and `fingerprintSchemaVersion`; v5 and v6 signatures are
not interchangeable.

### Confidence

Confidence is the floor of route and structural evidence:

- `high`: explicit developer alias such as `TugboatTag`/stable value key;
- `medium`: usable structural path and/or structural route fallback;
- `low`: ambiguous structure, bare collapsed item, or insufficient actionable
  evidence.

Confidence is evidence quality, not a uniqueness guarantee. Consumers should
corroborate low-confidence matches rather than treating them as ground truth.

### What is and is not retained

The structural pipeline does not serialize arbitrary `Text`, accessibility,
tooltip, or icon-label strings. Candidate static labels are inspected only to
decide whether a hashed discriminator is safe.

Developer-authored identity strings can still be emitted:

- named routes;
- `TugboatTag.id` in target fingerprint parts, plus its hash alias;
- `TugboatSubView.label`;
- widget type names or configured `widgetNames` replacements;
- canonical structural paths.

Interaction events may also carry a `controlValue` payload (schema version 4) for
valued controls (checkbox, switch, radio, slider, dropdown / menu item, chip)
and for hit targets that expose Flutter semantic annotations:

- bools and numbers are emitted literally;
- enums and developer identifiers are emitted literally;
- arbitrary strings, including numeric strings and single-word values, are
  emitted literally;
- explicit custom-control values can be supplied with
  `TugboatControlValueScope`, including a stable `controlKey`, optional unit,
  and numeric `min`, `max`, and `step` metadata.

`tap` includes a `controlValue` snapshot sampled at pointer-down.
`tap_settled` uses the distinct `controlValueTransition` contract with
`before` / `after` snapshots. Its post-callback sample stays bound to the
original hit element, so later taps, route changes, or dismissed overlays
cannot donate unrelated control state. Slider drags that become `swipe` events
carry a `controlValue` snapshot sampled at pointer-up.

When a typed widget value is unavailable (custom GestureDetector rows, bottom
sheets, etc.), the SDK still samples `SemanticsProperties` / live semantics
nodes under the pointer and records raw `semanticValue` / `semanticLabel`.
Standard controls may include both widget
state and semantic annotations under `sources: ["semantics","widget"]`.

Independently, every interaction event (`tap`, `tap_settled`, `swipe`,
`scroll_start`, `scroll_end`) may carry a top-level `semanticAnnotation`
payload (schema version 2) whenever Flutter semantics expose an identifier, label, value, or
selection flag on the target. This covers ordinary buttons and scrollables as
well as valued controls. The field is named `semanticAnnotation` to avoid
colliding with `tap_settled.data.settleObservation.semantic` (state-signature
change evidence).

Bounds, pointer coordinates, scroll metrics, and masked screenshot pixels are
also capture data. Apps must treat tags, route names, subview labels, and
semantic value/label tokens as telemetry and avoid putting raw user PII in
them.

## Screenshot pipeline

Screenshots are taken from the SDK `RepaintBoundary` at the configured pixel
ratio (default `0.75`). Before PNG encoding the SDK collects mask rectangles
using the shared anchor resolver and paints them onto the raster.

The default mask policy is profile-dependent:

- `exploration`: explicit `TugboatSensitive` subtrees only;
- `productionLean`: all rendered text, editable inputs, and images.

The public mask levels are `explicitOnly`, `allTextAndMedia`, `allText`,
`allTextExceptActionable`, and `sensitiveInputsOnly`.

Capture uses a 9x8 perceptual dHash before PNG encoding to skip a visually
unchanged raster, then SHA-256 content hashing to deduplicate encoded frames.
Capture requests are serialized and coalesced; repeated state signatures are
also skipped unless a caller forces capture.

PNG readback and encoding still happen through Flutter image APIs on the UI
isolate. Platform views, video textures, maps, and native overlays may be absent
or incomplete in repaint-boundary output.

When the exploration WebSocket connects and there is no HTTP collector, the
controller suppresses new Flutter screenshots for UI-thread performance.
Events, anchors, inventories, and semantic evidence continue to stream. Any
frames captured before connection are still sent.

## Viewport semantics

`viewportSemanticMode` resolves with the capture profile:

| Mode | Engine | Emits map events | Debug logs |
| --- | --- | --- | --- |
| `off` | no | no | no |
| `tapResolutionOnly` | yes for active profiles | no | no |
| `full` | yes | exploration only | no |
| `fullWithDebugLogs` | yes | exploration only | exploration only |

Exploration holds a persistent Flutter `SemanticsHandle` when semantics are
enabled. Production uses transient semantics and never emits semantic-map
events, even in `full` modes; it can still build maps locally for tap
resolution. Emitted exploration maps are bounded by
`viewportSemanticMapMaxNodes` (default `120`) and
`viewportSemanticMapMaxBytes` (default `48000`).

Scene inventory and viewport semantic maps are related but distinct:
inventories enumerate actionable structural controls; semantic maps add
viewport-level semantic resolution and scroll context. Tap resolution can use
semantics without emitting map events.

## Transport boundary

The controller fans evidence to zero, one, or both built-in sinks:

- an exploration WebSocket configured by `explorationCollectorUrl`;
- an HTTP sink configured by `collector`.

The sink hub isolates synchronous and asynchronous sink failures. Capture
remains authoritative in memory. Public `TugboatCaptureSinkFactory` registration
is supported via `TugboatReplayConfig.sinkFactories`; built-in HTTP/WS sinks
remain available through existing config fields.

HTTP delivery can optionally use a durable outbox (`TugboatOutboxConfig`).
Exploration WebSocket queues remain process-local. See
[Collector integration](../integration/collector.md) for the wire behavior.

## Lifecycle

- `wrapApp` always mounts a lightweight activation gate (unless disabled).
- Session start waits for a non-zero repaint-boundary or media-query viewport.
- `paused` and `hidden` schedule a sink flush after 500 ms.
- `resumed` cancels a pending background flush.
- `detached` ends the session.
- Wrapper disposal/deactivation emits `session_end` once, asks sinks to end,
  then disposes them asynchronously.
- The HTTP sink flushes on batch size, periodically, and before session end.

## Verified implementation coverage

The package test suite covers deterministic fingerprints, list-length and
scroll stability, dynamic-label exclusion, static list discriminators, tag
transparency, route separation, modal/visibility filtering, generated widget
names, actionable `InkWell` paths, dormant activation without rebuild,
screenshot mask defaults, route payloads, scroll/swipe attribution, schema-v7
JSON with v6 read compatibility, semantic modes, sink factories/mailboxes,
outbox restart recovery, health diagnostics, lifecycle ordering, retry bounds,
and stale session/frame protection.

These tests prove repository behavior; they do not replace validation on real,
obfuscated release builds or app-specific navigator/overlay structures.

## Remaining gaps and follow-ups

### 1. Release-build identity matrix

Continue exercising `--obfuscate`, nested navigators, platform views, and
overlay-heavy screens on representative devices. Obfuscated builds without
generated `widgetNames` must fail the compatibility gate rather than invent
cross-build equivalence.

### 2. Screenshot budget device baselines

Unit thresholds live in `benchmark/screenshot_budget_baseline.dart`. Record
multi-tier device measurements before enabling aggressive degradation in
production profiles.

### 3. Stronger collector acknowledgement

Outbox delivery is at-least-once with local idempotency keys. Server-side
envelope dedupe remains a collector concern.

### 4. Deferred capture surfaces

Native platform-view adapters, video texture capture, and iOS background upload
services remain out of scope.

### 5. Cross-build compatibility outside the SDK

The SDK correctly emits build metadata plus fingerprint schema version, but it
does not decide when two identities from different APKs are equivalent. The
enhancement/Atlas API should own lookup, confidence, and remap semantics without
weakening the SDK's build-scoped identity invariant.
