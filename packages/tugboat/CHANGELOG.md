## 0.6.0

### Added

- **Provider-neutral app-event hook** — `TugboatReplay.eventHook` records one
  logical `external_event` on the evidence stream with a bounded parameter
  policy (`namesOnly`, `allowList`, `transform`, or exploration-only
  `allowAll`). Values are deep-copied at hook time; dormant/disabled calls are
  safe no-ops.
- **Generic network observation** — `TugboatReplay.beginNetworkCall` exposes an
  exactly-once token for method, safe route template, status, outcome, and
  duration. No headers, queries, bodies, raw errors, or stack traces are
  retained.
- **Evidence isolation** — external and network evidence stamp session identity
  only and never inherit active exploration `actionId`, `relatedEventId`, or
  target/state anchors.
- **Evidence health counters** — `TugboatSdkHealth.evidence` exposes bounded
  accepted/dropped/duplicate-finish counts without retaining rejected raw
  values.
- **`tugboat_dio` companion package** — Dio interceptor that maps request
  lifecycle callbacks onto the core network token without importing Dio into
  core.

## 0.5.0

### Breaking changes

- **Control-value and semantic-annotation telemetry** — session JSON writers
  now emit schema version 9 and no longer write `controlValue`,
  `controlValueTransition`, or `semanticAnnotation` in event `data`.
  Readers that support historic schemas should continue to tolerate versions
  6–8, where those fields may be present.
- **Removed public barrel exports** —
  `TugboatEncodedControlScalar`, `TugboatVisibleControlValue`,
  `TugboatControlValueScope`, `TugboatControlValue`, and
  `TugboatSemanticAnnotation`.
- **Removed public schema constants** —
  `tugboatControlValueSchemaVersion`,
  `tugboatControlValueTransitionSchemaVersion`, and
  `tugboatSemanticAnnotationSchemaVersion`.
- **Removed public extraction and merge helpers** —
  `tugboatControlValueForWidget`,
  `tugboatControlValueFromSemanticsProperties`,
  `tugboatControlValueFromSemanticsNode`,
  `tugboatSemanticAnnotationFromProperties`,
  `tugboatSemanticAnnotationFromNode`,
  `tugboatMergeSemanticAnnotations`, and `tugboatMergeControlValues`.

## 0.4.18

### Fixed

- **Semantic parameter pairs in overlays** — interactions in dialogs and
  popovers now retain the accessibility label and raw value supplied by the
  visible control, rather than metadata from an obscured control beneath it.

## 0.4.17

### Changed

- **Raw control and semantic values** — control values, semantic values, and
  semantic labels are now sent verbatim instead of being tokenized. This makes
  slider positions, durations, and template identifiers available for session
  summaries and aggregate analysis.
- **Explicit custom-control values** — `TugboatControlValueScope` exposes a
  stable `controlKey`, typed number/duration/enum value, optional unit, and
  numeric range metadata for controls whose value is not readable from a
  standard Flutter widget.

## 0.4.16

### Added

- **Privacy-safe interaction metadata** — valued controls and semantic
  annotations can enrich tap, settle, swipe, and scroll events without
  retaining arbitrary semantic text.

### Changed

- **Causal control-value transitions** — settled control values are captured
  from the original interaction target and use a distinct transition payload.
- **Canonical interaction parity** — canonical-only tap and swipe results retain
  their post-interaction control and semantic metadata without relying on
  legacy projection events.
- **Cross-SDK semantics flags** — checked-state capture compiles on the
  package's declared Flutter 3.35 minimum and newer enum-based SDKs.

## 0.4.15

### Added

- **Canonical `interaction` events** — each finalized gesture emits one
  `stream: semantic` record with immutable `origin`, `result`, `attribution`,
  and `evidenceEventIds` (`interactionSchema: 1`). Legacy `tap` / `tap_settled`
  / `swipe` continue as dual-write peers on `stream: legacy_projection`.
- **Evidence stream** — `route_change`, `state_change`, `scroll_start`,
  `scroll_end`, and `pointer_cancel` emit on `stream: evidence` so default
  semantic enrichment selects only canonical interactions.
- **`enrichmentCandidate`** on collector-mapped events — false for evidence,
  diagnostic, and legacy-projection records; true for canonical `interaction`
  (and compat semantic tap/tap_settled/swipe when canonical emission is off).
- **Delayed reconciliation window** — `interactionClaimWindow` defaults to
  1,250 ms. A released tap can claim the first eligible visible route/modal
  successor in that window (`interactionAttribution: delayed_likely`). Set the
  window to `Duration.zero` to retain microtask-only same-turn claims.
- **Diagnostic stream isolation** — `capture_diagnostic` events carry
  `stream: diagnostic` so enrichment/insight queries can ignore them by
  default. Session health still aggregates outcome counts.
- **`causedByInteractionId`** on claimed `route_change` / `state_change`
  (alongside existing `causeEventId`).

### Fixed

- **Swipe origin freeze** — swipe events retain the pointer-down state anchor
  rather than refreshing live controller state at pointer-up.
- **Settle waits for delayed successors** — when the claim window is active,
  tap settlement holds until a successor claims or the deadline expires instead
  of finalizing `unknown` immediately.
- **Terminal cancelled interactions** — abandoning a pending/released
  transaction (lifecycle, session end, supersede, post-up cancel) publishes a
  canonical `gesture=cancelled` interaction instead of silently dropping it.

## 0.4.14

### Fixed

- **Automatic-navigation visual continuity** — when a route transition
  supersedes an in-flight tap capture, `tap_settled` now waits for and attaches
  the route's fresh frame as a non-causal `visual_successor`. A pointer-generation
  fence prevents later user interactions from being attached to the earlier tap.

## 0.4.13

### Fixed

- **Deferred tap emission** — `tap` is sampled at pointer-down but only emitted
  after gesture classification at pointer-up. Flick-scrolls no longer mint
  phantom taps; swipes carry `startCaptureCoordinate` instead of
  `relatedEventId` to a never-settled tap.
- **Same-turn interaction claims** — released pointer-up claims attribute
  `route_change` only through the pointer-up turn (`same_turn`). A wall-clock
  claim window incorrectly bound automatic redirects to taps; `interactionClaimWindow`
  defaults to zero and no longer extends attribution. Pre-up claims still work
  while the pointer is down (long-press → navigate).
- **Pre-up claim + swipe/cancel** — routes that claim before pointer-up no longer
  force a normal interaction tap; the buffered tap publishes as `causal_only`
  when the gesture finalizes as swipe/cancel (or at `route_change` publish).
- **Lifecycle claim fence** — backgrounding drops pending/released pointer claims
  so resume/navigation cannot attribute a pre-background gesture.
- **Session-end claim fence** — pending pointers are abandoned without emitting
  orphan `causal_only` taps when the claimed route was cancelled before publish;
  further pointer-down/up/cancel is ignored.
- **Duplicate pointer-down** — a second down on the same pointer abandons the
  prior pending claim instead of silently overwriting it.
- **Claim map hygiene** — `_claimsByTapEventId` entries are removed when a claim
  emits, drops, or expires; `invalidatesRelatedTap` is always a boolean.
- **Monotonic deferred publish** — buffered taps / `tap_outside_tree` publish at
  emission `atMs` with `sampledAtMs` preserving pointer-down time.
- **Gesture promotion** — `tap_gesture_resolved` (`promotesRelatedTap`) plus an
  in-memory `replayRole` patch promote genuine taps that were first published as
  `causal_only` for a pre-up route claim.
- **Missing-frame coordinates** — `unavailableReason: missing_frame` now keeps
  boundary-local / normalized geometry when the boundary rect is known, instead
  of zeroing local/normalized fields.

## 0.4.12

### Added

- **Navigator and route-instance ownership** — every observed Navigator gets a
  session-local opaque `navigatorId`; every pushed route gets a
  `routeInstanceId`. Stacked anonymous modals stay distinguishable.
  Install nested observers with `TugboatReplay.createNavigatorObserver()`.
- **Navigation origin contract** — `route_change` events carry
  `navigationOrigin` (`interaction` | `automatic_or_unknown`) and optional
  `causeEventId`. Only observer-time single-use pending-interaction claims can
  bind a tap; timer/auth redirects never fabricate causality.
- **Versioned `captureCoordinate`** — taps retain legacy global `x`/`y` and add
  a boundary-local / normalized / raster transform bound to the before-frame.
  Outside-boundary and generation-mismatch cases emit an unavailable reason
  instead of clamping.
- **Replay coherence characterization harness** — deterministic, advanceable
  scheduler/capture test seams (`debugNow`, `debugDelay`, `debugExecuteCapture`,
  `debugSeedFrame`) plus reusable helpers that reproduce known navigation/frame
  races without wall-clock sleeps. Tracks milestone issue #5.
- **Pathless-tap snap** (2026-07-04) — when hit-testing resolves a tap to a target
  with a role but no canonical path (opaque `Texture`, decorated boxes outside the
  token map), the tap is re-anchored to the smallest *interactive* scene-inventory
  element containing the tap point, so its fingerprint always joins the inventory.
  Guards: only interactive-tier entries qualify, and the candidate's area must be
  comparable to the render surface the pointer actually hit (occluded controls under
  opaque overlays are never falsely attributed). Snapped anchors keep
  `tagFingerprint`, drop stale `fingerprintParts`, and are marked
  `fingerprintConfidence: 'low'`.
- **Structurally addressable anchor preference** — `_targetAtWithTokenMap` prefers
  hit-test candidates that have both a role and a non-empty canonical path over
  role-only candidates, fixing joins for paywall dismiss buttons and overlay chrome.
- **`scene_inventory` events** — during exploration, emit a deduped structural inventory
  of actionable elements and `Image` widgets per settled screen state (fingerprints, bounds,
  roles). Fingerprints match tap `targetAnchor` resolution for the same element.
- **Fingerprint aliases** — inventory entries store alternate structural fingerprints for the
  same logical control (e.g. wrapper layers like `InkWell` vs `GestureDetector`). Tap
  resolution can match via primary fingerprint or alias.
- **Tap injection** — when a tap resolves to a fingerprint not in the enumerated inventory,
  the tap target is appended to the inventory so exploration joins are guaranteed.
- **Route epoch guard** — stale delayed route callbacks no longer clobber `_currentRoute` or
  emit incorrect `route_change` events during rapid navigation.
- **Item-normalized state signatures** — `[item:hash]` segments in actionable paths are
  normalized to `[item]` for signature hashing only, so list scroll does not fork inventories
  for the same logical screen.
- **Capture attribution diagnostics** — SDK emits `action_window_set`, `action_window_cleared`,
  `tap_outside_tree`, and `pointer_cancel` events during CLI exploration runs.
- **`recordPointerCancel`** — wired from `InputCapture` and the root `Listener` so cancelled
  gestures are visible in the event stream.

### Changed

- **Tap/navigation causality fence** — tap settlement joins a route-capture
  barrier only when that route explicitly claimed the same tap event.
  Automatic redirects that overlap settlement, including successors of a
  tap-caused route, remain independent and cannot donate their frame or route
  event ID to the tap.
- **Frame-owned coordinate geometry** — frame provenance now retains the
  capture boundary's logical rect and transform generation. Resizes, rotations,
  and inset changes invalidate stale before-frame attachment and emit
  `generation_mismatch` instead of projecting a current tap onto older pixels.
- **Replay capture contract documentation** — documents the implemented route/frame
  attribution invariant separately from the still-open production acceptance
  gaps for rapid modal chains, automatic navigation, and playback tap-coordinate
  alignment.
- **Route-capture barrier** — tap settlement now joins the matching route epoch
  instead of reusing the previous route's latest frame. Supersession,
  lifecycle cancellation, capture failure, and bounded timeout outcomes
  complete deterministically without allowing late readbacks to publish.
- **Production viewport semantics stay local** — production sessions can still
  build viewport semantic maps for tap resolution, but `viewport_semantic_map`
  and `scroll_semantic_snapshot` events are emitted only during exploration so
  UI text from semantic nodes is not uploaded in lean production captures.
- **`ExplorationCaptureSink.recordFrame`** — forwards frame metadata and PNG bytes over the
  exploration WebSocket instead of dropping them. The CLI persists these under `frames/` when
  Flutter capture produces them (local capture may still be suppressed after the socket connects
  for performance; see `collector-integration.md`).
- **`actionableSummary` deduplication** — count only leaf canonical controls (one per
  `FilledButton`/`TextButton`, not nested ink-well chrome). Fixes over-counting in modal,
  visibility, and rebuild fingerprint tests.
- **`nonAssetImagesOnly` contract narrowed to what is actually classified** — README and
  enum docs now state the mode masks non-asset `Image` widgets (such as `Image.network`,
  `Image.file`, and `Image.memory`) plus sensitive inputs. Custom-painted or decorated
  image surfaces (e.g. `ExtendedImage`, `DecorationImage`, `CustomPaint`) are not
  classified by this mode and must be wrapped in `TugboatSensitive` when private.
  Image-provenance detection is isolated in a single helper (`_isNonAssetImageWidget`)
  as the one place to extend classification later. Behavior is unchanged; regression
  tests cover asset-visible, memory-masked, and Sensitive-always-masked cases.
- **Typed route transitions in the controller** — `route()` converts raw navigator
  callback strings into an internal typed model (`_RouteNavigationKind`,
  `_RouteTransition`) and resolves visible navigation in one place
  (`_resolveVisibleRouteChange`), replacing string-driven branching and collapsing the
  two duplicate `route_remove` stack-cleanup checks into a single normalized decision.
  The `route_change` wire format (`data.fromRoute` / `data.route` / `data.navigation`)
  and epoch/capture semantics are unchanged; stack-cleanup removals from
  `pushNamedAndRemoveUntil` still never bump the route epoch or cancel the pending
  destination capture (now covered by a dedicated regression test).

### Removed

- **`control_inventory` SDK events** — the SDK no longer emits per-screen control
  inventories over the exploration WebSocket. Possible actions should be derived
  from screenshots (for example via a VLM) instead of SDK-side widget-tree scans.
  State anchors still include `actionableSummary` role counts for fingerprinting
  only; that field is not a substitute for control discovery.

## 0.1.0

- Initial Tugboat Flutter SDK with screenshot evidence, interaction anchors,
  route transitions, privacy masking, and exploration transport.
