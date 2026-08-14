## 0.8.5

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.5`.

### Breaking changes

- The SDK now publishes only schema-v2 canonical `interaction` gesture events.
  Removed legacy gesture projections, publication modes, session aliases, and
  compatibility constructors.
- Removed the on-device outbox and its public configuration. Collector and
  exploration delivery are best-effort through bounded in-memory queues.
- `interaction.afterFrame` now means a temporal post-interaction observation.
  An unclaimed route frame can satisfy it without creating route causality or
  an inferred result.

### Changed

- Production-friendly scroll capture now keeps scroll metrics independent from
  screenshots. In-motion scroll screenshots are opt-in, pressure-droppable,
  and disabled by default; pointer-linked scrolls retain one optionally
  deferred scroll-end observation.
- Screenshot output can be bounded with `captureMaxWidth` /
  `captureMaxHeight`. A degraded screenshot budget applies
  `degradedCaptureScale` before GPU readback, reducing raw RGBA allocation as
  well as encoded size.
- Low-priority captures dropped under active/queued capture pressure emit the
  bounded `capture_pressure_drop` diagnostic outcome.
- `capturePixelRatio` accepts values above `1.0`. Optional output bounds still
  cap the effective readback scale before allocation.
- Network observation accepts bounded absolute paths with dynamic identifier
  segments. Schemes, queries, fragments, encoded data, network-path prefixes,
  backslashes, whitespace, and control characters remain rejected.

### Fixed

- A new pointer-down cancels a pending deferred scroll-end screenshot before
  Flutter reports the next `ScrollStart`. The completed scroll keeps its final
  offsets, overscroll count, target fingerprint, and interaction record, but it
  does not block or consume the new gesture.
- Tap-only target, inventory, and viewport-semantic resolution now runs after a
  gesture remains a tap. Scroll gestures no longer pay that work on
  pointer-down.
- Scroll completion joins pointer-up and `ScrollEndNotification` in either
  callback order and publishes one canonical interaction. Pointer cancellation,
  replacement scrolls, lifecycle changes, and programmatic scrolls do not leave
  a late interaction screenshot request.
- Interaction after-frames must complete after the interaction boundary. A
  pre-pointer-up frame cannot become an after-frame, including frames from a
  claimed route capture that settles while the pointer is still down. An
  unrelated automatic route cannot add causal route evidence to the interaction.
- Tap target resolution uses the pointer-down position so a slop-bounded
  release cannot resolve a sibling control or miss the recognizer's original
  target.
- Screenshot capture pixel-ratio clamp results are explicitly converted to
  `double` for sound null-safety.

## 0.8.0

### Changed

- Raw SDK writers no longer emit `stateAnchor`, `stateSignature`, or
  `state_change` events. Session wire schema 10 identifies this contract and
  the serialized `interaction` frame trigger. Completed interactions request
  one fresh after-frame.
- Collector event mapping now omits `stateAnchor`. Deploy the serial collector
  compatibility patch before sending 0.8.0 recordings to a collector that
  still requires that key.
- Production collector events for `interaction` and `route_change` use flat
  schema-v2 wire shapes (`interactionSchema` or `routeChangeSchema` == `2`) with
  facts-only fields. The mapper no longer emits empty `targetAnchor` objects or
  duplicates `stream` inside generic `payload`. Interaction v2 drops inferred
  `result`, nested `origin`/`result`, and tap-settle outcome computation.
- `interaction` schema v2 carries gesture-specific facts under a nested
  `payload` (`position` for tap; `position`/`endPosition`/`delta` for swipe;
  `position`/`startOffset`/`endOffset`/`overscrollCount` for scroll). Cancelled
  interactions omit `payload`. The SDK no longer emits `scroll_start`,
  `scroll_end`, or `pointer_cancel` — scroll and cancel semantics live on
  `interaction` only.

## 0.7.1

### Changed

- **Screenshot capture performance** — remove the post-capture state-signature
  short circuit and replace it with a paint-signature gate that skips the full
  GPU readback/encode path when the capture subtree (including nested
  `RepaintBoundary`s) has not painted. Diagnostic outcome
  `state_signature_short_circuit` is replaced by `paint_generation_unchanged`.
- **Encode path** — JPEG encoding, SHA-256, mask fills, and dHash now run on a
  persistent background isolate with transferable RGBA input. dHash coalesce
  tolerates Hamming distance ≤ 2. Default screenshot budget is 60 ms / 5 s.
- **Collector uploads** — frame wire format docs corrected to JPEG. Pending
  frames are not superseded on enqueue: events reference exact frame IDs and
  multipart upload has no hash alias.

## 0.7.0

### Added

- **Explicit production parameter opt-in** —
  `TugboatParameterPolicy.allowAllInProduction` retains JSON-safe external-event
  parameter values in production capture profiles. `namesOnly` remains the
  default. `allowAll` remains an exploration-only escape hatch and still
  downgrades to names-only outside exploration. The existing JSON and size
  bounds still apply. This policy can retain feedback, search terms, URLs, IDs,
  and other user content. Hosts must confirm consent, privacy, access, and
  retention rules before they use it.

## 0.6.0

### Changed

- **Canonical interactions are now the recording default** —
  `TugboatReplayConfig.interactionPublishMode` defaults to `canonicalOnly`, so
  each finalized gesture emits one semantic `interaction` instead of also
  emitting `tap`, `tap_settled`, or `swipe` compatibility rows.
- **Legacy gesture publication is deprecated** — `dualWrite` and `legacyOnly`
  remain explicit migration overrides for historical consumers. New
  integrations must not enable them; removal prerequisites and the searchable
  `TODO(tugboat-legacy-projection-removal)` marker are documented in the SDK
  README.

### Added

- **Provider-neutral coded-event hook** — `TugboatReplay.eventHook` records one
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

### Fixed

- **Session-bound evidence completion** — in-flight network tokens can no
  longer finish into a replacement session, and session end fences reentrant
  evidence before publishing its terminal event.
- **Production parameter policy** — exploration-only `allowAll` is downgraded
  to names-only outside exploration, and unsupported values contribute one
  drop to bounded diagnostics.
- **Session-end admission** — session end claims its in-flight future before
  sync sink work, so evidence fencing no longer needs a separate ending bool.
- **Deactivate evidence fence** — `TugboatReplay.deactivate` closes evidence
  admission immediately; the activation gate still owns `session_end` on
  teardown.

## 0.5.3

### Added

- **Debounced identity coalesce** — after `session_start`, `setUserId` and
  `setTraits` within 3s consolidate into one `session_identify` POST when
  both change; otherwise `user_changed` or `traits_updated`. Pending updates are
  flushed before `session_end`.

### Changed

- Pre-start identity still folds into a single `session_start` when values are
  staged before or while start is pending.

## 0.5.2

### Changed

- **`setUserId` folds into pending `session_start`** — when a `session_start`
  is still pending, `CollectorHttpSink.setUserId` updates the runtime id only
  and skips `user_changed` (same coalesce already used by `setTraits`). Boot
  identity can land on a single `session_start` POST.

## 0.5.1

### Added

- **User traits via collector sessions** — `TugboatReplay.setTraits` posts
  `eventType: traits_updated` on `POST /v1/sessions` with a full traits bag,
  caches the response `traitsId`, and stamps it on event batches.
  `TugboatReplay.setUserId` posts `user_changed` and updates the runtime user
  id. Pre-set traits are included on the next `session_start`. No
  `/v1/identify` route.

### Changed

- **`setUserId` skips unchanged ids** — calling `TugboatReplay.setUserId` /
  `CollectorHttpSink.setUserId` with the same value as the current runtime
  user id does not post `user_changed`.
- **Pre-initialize identify** — `setTraits` / `setUserId` called after the
  controller mounts but before the HTTP sink is created retain identity for
  the next `session_start` instead of dropping it.

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
