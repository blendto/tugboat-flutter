---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
created: 2026-07-28
---

# SDK interaction consolidation: attribution, outcomes, and noise

## Goal

Make Tugboat emit one authoritative semantic interaction for every completed
user gesture. That interaction must retain the screen/modal and component that
were visible when the gesture began, classify the final gesture correctly, and
attach a causally supported visual result when one occurs shortly afterwards.

The SDK must stop asking the collector, dashboard, or Context Graph to infer
these relationships from unrelated top-level callbacks.

## Problem frame

The current controller has deferred-tap and same-turn causal-claim machinery,
but it still finalizes many pointer-up interactions before delayed Flutter
navigation occurs. The result is a `tap_settled` with `unknown` while the route
or bottom sheet appears separately. In other paths, settlement refreshes
current context after navigation and risks attaching the interaction to the
destination rather than the origin component.

The raw stream is also too broad for semantic enrichment: a single scroll can
produce a provisional tap, `scroll_start`, `swipe`, and `scroll_end`; a tap can
be represented by both `tap` and `tap_settled`; and `capture_diagnostic`
records are mixed into normal session activity. A production 0.4.0 session
A later Blend production session had 570 records: 202 `tap`, 151 `tap_settled`, and
161 scroll-related records. This creates false candidates for enrichment and
inflates insight calculations such as rage taps.

## Product contract

### Requirements

- **R1 — Immutable origin.** At pointer-down, capture and retain the origin
  state anchor, route/modal identity, component target anchor, capture
  coordinate transform, pre-interaction frame, and monotonic timestamp. No
  later route/state refresh may overwrite those fields.
- **R2 — One canonical interaction.** Publish exactly one normal-stream
  semantic record for each finalized user gesture: `tap`, `swipe`, `scroll`, or
  `cancelled`. `tap_settled` must no longer be a second independently enriched
  action.
- **R3 — Delayed causal result.** Hold a released tap in a bounded
  reconciliation window. The first eligible visible route, modal, or state
  successor in that window becomes its result, with origin and destination
  identities preserved explicitly.
- **R4 — Conservative attribution.** A competing pointer, a classified
  scroll/swipe, lifecycle interruption, an incompatible navigator/route epoch,
  or an expired window prevents causal attribution. Such transitions stay
  automatic; the origin interaction is finalized without a false result.
- **R5 — Gesture reclassification.** If a pointer becomes a scroll/swipe,
  suppress its provisional tap from the normal stream and emit one completed
  gesture summary with start/end positions, displacement, duration, and its
  origin target.
- **R6 — Evidence, not competitors.** Route/state/frame observations remain
  available as evidence and retain their own event records where required for
  capture/replay, but refer to the canonical interaction through stable IDs.
  They must not create additional enrichment candidates for the same gesture.
- **R7 — Insight-safe.** Rage tap and tap analytics operate on finalized tap
  interactions only. Scrolls, swipes, cancelled pointers, and taps with a
  successful route/modal/state result must not count as rage taps.
- **R8 — Diagnostic isolation.** Capture diagnostics are debug/health data,
  not user actions. Keep them in a separately marked channel or aggregate them
  into a session health summary so normal enrichment and insight queries ignore
  them by default.
- **R9 — Bounded overhead.** Consolidation is in-memory only. It must not
  persist every raw callback before classification, add screenshot/widget-tree
  captures, or use unbounded pending state.

### Non-goals

- Do not use dashboard post-processing or ClickHouse joins to repair SDK
  semantics.
- Do not infer a causal action from an arbitrary later automatic redirect.
- Do not remove raw diagnostic capability; isolate it from the semantic stream.
- Do not change privacy masking, frame encoding, or Context Graph matching
  rules except to consume the new explicit origin/result fields.

## Key technical decisions

1. **Interaction transaction, not upload-side repair.** Replace the current
   provisional-event/settlement representation with a bounded in-memory
   transaction per pointer. The durable outbox receives only finalized semantic
   events. This is the only layer that has reliable pointer, route, modal, and
   widget-tree timing together.

2. **Freeze origin at pointer-down.** The transaction owns an immutable
   `InteractionOrigin` value rather than calling `_refreshStateAnchor()` at
   settlement. It includes screen/modal route instance, target anchor,
   coordinate space, before-frame reference, and `pointerGeneration`.

3. **Bounded delayed reconciliation.** Replace the present
   `_PendingInteractionClaim.sameTurnEligible` rule with a short configurable
   reconciliation deadline after pointer-up. Eligibility additionally requires
   same navigator, compatible route epoch, no competing eligible interaction,
   and the first visible successor. Begin with a conservative 1,250 ms default;
   expose it only as an internal constant until production timing data warrants
   configuration.

4. **Canonical `interaction` envelope with compatibility projection.** Add a
   canonical inferred event shape (`type: interaction`, `gesture: tap|swipe|
   scroll|cancelled`) and project legacy `tap`/`tap_settled` only behind a
   temporary compatibility gate. The collector and graph should migrate to the
   canonical shape before the legacy pair is removed. This avoids a breaking
   ingestion cutover while ensuring one enrichment candidate per gesture.

5. **Observation links are explicit.** Store `origin`, `result`, and
   `evidenceEventIds` on the interaction. A route/state event also carries
   `causedByInteractionId` when claimed. No consumer has to use time adjacency
   to reconstruct the relationship.

6. **Final-state gesture classification wins.** A move past the existing
   gesture threshold irrevocably changes the transaction from tentative tap to
   scroll/swipe. Its provisional tap is never emitted as an action; the
   resulting summary keeps the same origin context.

7. **Separate semantic and diagnostic streams.** Keep diagnostics available
   for session health and support, but mark them `stream: diagnostic` and make
   normal collector/graph queries select `stream: semantic` by default.

## Target event model

```text
interaction
  id
  gesture: tap | swipe | scroll | cancelled
  origin:
    stateAnchor, routeInstanceId, navigatorId, targetAnchor,
    captureCoordinate, beforeFrame, atMs
  result:
    status: navigated | changed | unchanged | unknown | cancelled
    route/state/modal identity, afterFrame, observedAtMs
  attribution:
    direct | delayed_likely | none
    windowMs, rejectionReason?
  evidenceEventIds: [route_change?, state_change?, scroll_end?]
```

An independently automatic route keeps `causedByInteractionId: null` and
`navigationOrigin: automatic_or_unknown`. It is not retroactively claimed when
the transaction window has ended or a guard failed.

## Implementation units

### U1 — Introduce immutable transaction data and lifecycle

**Files**

- `packages/tugboat/lib/src/controller.dart`
- `packages/tugboat/test/replay/deferred_tap_emission_test.dart`
- `packages/tugboat/test/replay/navigation_origin_contract_test.dart`
- `packages/tugboat/test/replay/interaction_transaction_test.dart` (new)

**Change**

- Replace `_PendingInteractionClaim`'s event-buffer-centric lifetime with an
  `InteractionTransaction` that owns immutable origin data, gesture state,
  release/deadline timestamps, evidence IDs, and terminal status.
- Create the transaction at pointer-down before any post-frame or route work.
- Refactor `recordPointerUp`, `_abandonPendingPointer`, and lifecycle/session
  fences so every transaction reaches exactly one terminal state.
- Keep the existing pointer-generation and navigator/route-instance checks as
  transaction guards rather than recomputing origin context.

**Tests**

- Pointer-down on a component, then route mutation before pointer-up: emitted
  origin remains the original screen/component.
- Pointer-down in a modal and delayed modal dismissal: origin retains the
  modal, result retains the underlying route.
- Lifecycle/session end, cancellation, and duplicate pointer-down produce no
  stranded transaction or duplicate canonical interaction.

### U2 — Reconcile delayed visual successors without false claims

**Files**

- `packages/tugboat/lib/src/controller.dart`
- `packages/tugboat/test/replay/replay_navigation_race_matrix_test.dart`
- `packages/tugboat/test/replay/replay_programmatic_navigation_matrix_test.dart`
- `packages/tugboat/test/replay/replay_navigation_interaction_matrix_test.dart`
- `packages/tugboat/test/replay/interaction_transaction_test.dart` (new)

**Change**

- Route `_resolveVisibleRouteChange`, `_tryClaimInteractionCause`, route
  observer callbacks, and state-change capture through a single successor
  matcher.
- At pointer-up, move a tap from active to reconciliation-pending instead of
  emitting `unknown` immediately.
- Match only the first eligible visible successor before deadline; attach its
  post-transition frame and `causedByInteractionId`; finalize as `navigated`
  or `changed` with `attribution=direct|delayed_likely`.
- On deadline, finalize as `unchanged`/`unknown` against the frozen origin and
  leave subsequent routes automatic.
- Record a machine-readable rejection reason for every unclaimed successor
  (`expired`, `competing_pointer`, `gesture_reclassified`, `navigator_mismatch`,
  `automatic_guard`).

**Tests**

- Same-turn push/pop/replace, delayed 100 ms/500 ms/1,200 ms navigation, and
  delayed `ModalBottomSheetRoute` all produce one interaction with correct
  origin and destination.
- A redirect after the deadline, a timer-driven route with no tap, and a route
  following another pointer remain automatic.
- Two rapid taps can only claim their own first eligible successors; no route
  is linked twice.
- Each `navigated`/`changed` interaction has an `afterFrame` when capture is
  available; capture failure is explicit rather than silently changing origin.

### U3 — Finalize gesture classification and collapse gesture noise

**Files**

- `packages/tugboat/lib/src/controller.dart`
- `packages/tugboat/lib/src/input_capture.dart`
- `packages/tugboat/test/replay/deferred_tap_emission_test.dart`
- `packages/tugboat/test/replay/replay_coherence_characterization_test.dart`
- `packages/tugboat/test/scroll_attribution_test.dart`

**Change**

- Refactor `markPendingTapAsSwipe` and scroll callbacks so they mutate one
  transaction instead of emitting a causal tap plus `swipe`, `scroll_start`,
  and `scroll_end` as semantic peers.
- Emit one finalized `interaction(gesture=scroll|swipe)` after scroll end or
  pointer-up. Keep low-level scroll observations only as linked evidence or
  diagnostic detail.
- Preserve the existing `startCaptureCoordinate` and transform metadata on the
  finalized interaction so coordinate-based enrichment and replay markers stay
  correct.

**Tests**

- A drag produces zero semantic taps and exactly one semantic scroll/swipe.
- A small movement below threshold remains one tap.
- Overscroll, pointer cancel, and interrupted drag produce one terminal
  interaction with no provisional-tap leak.
- Coordinate transform, insets, and scaled capture fixtures retain the origin
  target and correct normalized position after reclassification.

### U4 — Publish canonical interactions and isolate diagnostics

**Files**

- `packages/tugboat/lib/src/models.dart`
- `packages/tugboat/lib/src/controller.dart`
- `packages/tugboat/lib/src/capture_sink.dart`
- `packages/tugboat/lib/src/outbox/outbox.dart`
- `packages/tugboat/lib/src/outbox/outbox_sink.dart`
- `packages/tugboat/lib/src/collector_http_sink.dart`
- `packages/tugboat/test/replay/replay_coherence_characterization_test.dart`
- `packages/tugboat/CHANGELOG.md`

**Change**

- Add the canonical interaction schema, event stream marker, origin/result
  payloads, evidence IDs, and compatibility-version marker.
- Place the semantic-publication gate immediately before `_addEvent`. The
  capture sink hub, outbox sink, and collector HTTP sink each serialize or
  queue events immediately, so none can safely be made responsible for
  consolidation. Enforce one terminal inferred event per transaction ID before
  it reaches any sink.
- Move `_recordCaptureDiagnostic` to the diagnostic stream and define a compact
  end-of-session health aggregate for production observability.
- Retain temporary legacy projection behind a documented feature/version gate;
  it must point to the canonical interaction ID and be excluded from default
  enrichment selection.

**Tests**

- Serialization round-trip preserves immutable origin and successor result.
- Outbox recovery never duplicates a finalized interaction or loses its
  evidence IDs.
- Normal inferred event selection excludes diagnostics and legacy projections.
- A session with 10 gestures publishes 10 canonical semantic interactions,
  regardless of raw pointer/route/scroll callback count.

### U5 — Migrate enrichment, insights, and acceptance gates

**Files**

- `docs/integration/production-replay-acceptance-0.4.13.md`
- `docs/integration/production-replay-acceptance.md`
- `packages/tugboat/README.md`
- Context Graph/collector consumer repositories, in follow-up PRs after the
  SDK schema lands

**Change**

- Make enrichment select canonical semantic interactions and map components
  using `origin.targetAnchor`, never the current/destination route context.
- Build causal edges from `result`/`causedByInteractionId`, not arrival order.
- Define rage tap as repeated completed `gesture=tap` on the same origin target
  within the insight window with no successful result. Exclude scroll/swipe,
  cancellation, and `navigated`/`changed` interactions.
- Replace legacy acceptance metrics (`raw tap`, `swipe-consumed`, settled-pair
  ratios) with canonical interaction coverage, origin/destination correctness,
  delayed-success attribution, automatic-route false-claim rate, and semantic
  event reduction.

**Tests and production checks**

- Fixture/replay ingestion maps a delayed navigation to the correct origin
  component and destination screen.
- Rage-tap fixture with three no-result taps flags once; three scrolls or three
  successful navigation taps do not.
- Production Blend flow covers home scroll, paywall, full-screen navigation,
  modal bottom sheet, asynchronous onboarding transition, rapid double-tap,
  and automatic redirect.

## Sequencing and compatibility

1. Land U1 and characterization tests first; no externally visible schema
   change yet.
2. Land U2 and U3 in small commits with the race/gesture matrix. Release behind
   an internal consolidation flag enabled for Blend only.
3. Land U4 with dual-write compatibility projection; collector/graph continue
   reading legacy records during migration.
4. Land U5 consumer changes and update production acceptance queries.
5. Compare dual-written sessions. Remove legacy `tap` + `tap_settled` semantic
   selection only after all acceptance gates pass for two representative Blend
   flows and no consumer still relies on it.

### Migration status — 2026-08-06

- The canonical `interaction` schema and temporary compatibility projection are
  implemented.
- New recordings now default to `canonicalOnly`; `dualWrite` and `legacyOnly`
  require an explicit override and are deprecated for new integrations.
- Collectors and replay readers must continue accepting historical legacy rows,
  but enrichment, insight, and flow-attribution paths must select canonical
  semantic `interaction` records.
- Final emitter deletion is intentionally deferred. Track it through
  `TODO(tugboat-legacy-projection-removal)` and the removal checklist in
  `packages/tugboat/README.md`.

## Performance and safety budget

- Maximum pending transactions: one per active pointer plus a small bounded
  released queue; reject/flush oldest safely if the cap is reached.
- Default reconciliation deadline: 1,250 ms; implementation must record timing
  distribution so the value can be tuned from production evidence.
- No widget-tree traversal, screenshot capture, disk I/O, or network call may
  be introduced solely by consolidation.
- Use existing route/state/frame observations; references, not cloned frame
  bytes, are stored in transactions.
- Expiry uses one controller sweep/clock hook, not unbounded per-event timers.

## Definition of done

- No finalized interaction ever changes its origin screen/modal/component after
  pointer-down.
- Delayed user navigation and bottom sheets in the configured window produce a
  single causal interaction with origin and destination fields.
- Automatic redirects and competing interactions are not falsely claimed.
- A completed scroll/swipe creates no semantic tap.
- Default downstream selection sees exactly one semantic action per completed
  user gesture and excludes diagnostics.
- Rage tap uses finalized canonical taps and passes the positive/negative
  fixtures above.
- Focused replay tests, full package analysis, formatting, and Blend production
  acceptance all pass.

## Risks and decisions to validate during implementation

- A fixed reconciliation window may be too short for slow network-driven UI or
  too long for automatic redirects. Instrument pending-to-success latency and
  make the deadline data-driven after the Blend rollout.
- Some state changes are visual consequences rather than user-visible
  destinations. Only first visible successor evidence should close a tap.
- Legacy collector and graph consumers may currently assume `tap_settled` is
  the canonical enrichment record; dual-write and consumer migration are
  mandatory before deleting that shape.
- Multi-pointer gestures and native/platform overlays need explicit
  characterization before enabling causal attribution for them.
- `interactionClaimWindow` is currently constrained to same-turn eligibility
  for compatibility. U2 must replace that policy deliberately rather than
  merely changing configuration, and record the migration in the public
  configuration documentation.

## Verification contract

1. Run focused replay matrices for U1–U4, then all package tests and static
   analysis/formatting.
2. Build Blend against the local SDK and manually exercise the acceptance flow.
3. Query ClickHouse by SDK version and canonical interaction schema version.
4. Score origin correctness, delayed attribution, false claims, inferred event
   count per completed gesture, diagnostic-stream isolation, and rage-tap
   precision.
5. Publish a side-by-side report against a locked 0.4.0+ baseline before
   removing legacy projection.
