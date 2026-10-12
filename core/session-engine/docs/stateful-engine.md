# Stateful session engine design

Status: Accepted · 2026-10-12 · ADR 0009 slice 3

This document designs the stateful half of the session engine: session state,
the clock model, interaction transactions built from adapter facts, navigation
and capture coordination, and collector delivery. It builds on the stateless
message protocol in [README.md](../README.md) and the golden fixtures in
[conformance/](../../../conformance/README.md).

Section 11 records the decision on every behaviour change, and section 12
records the open questions. All of them were decided on 2026-10-12.

The behaviour changes apply to the engine only. The Flutter adapter keeps its
shipped Dart behaviour until it moves onto the engine (Q1).

## 1. Goals and non-goals

Goals:

- Move every platform-neutral decision that `TugboatReplayController` and
  `CollectorHttpSink` make today into the engine, so the Android, iOS, React
  Native, and (later) Flutter adapters share one implementation.
- Keep the engine deterministic: the same message sequence always yields the
  same records and effects, so scenarios can be golden fixtures.
- Preserve today's wire behaviour unless section 11 lists a deliberate change.

Non-goals:

- Pixels, JPEG bytes, sockets, disk, and timers. The host owns them.
- Reading the UI tree. The toolkit adapter owns it.
- Collector-side changes. Anything that needs the collector to change is an
  open question (section 12), not a decision here.

## 2. Principles

1. **The engine never reads a clock.** Every stateful message carries the
   time it describes. Timers are effects; their expiry is an input.
2. **The engine never asks the adapter about the past.** Anything that reads
   the live UI tree (target anchor, scrollable identity, route identity, focus
   kind, paint signature) is computed by the adapter at the moment of the fact
   and travels with the fact. This is what makes an asynchronous seam
   (Pigeon, the RN bridge) safe: by the time the engine answers, the tree may
   have changed.
3. **The host owns bytes; the engine owns decisions.** The engine queues frame
   *handles* and metadata. It tells the host when a handle may be released.
   Raw pixels and JPEG bytes never enter the engine.
4. **Every effect that expects an answer carries a request id.** The engine
   ignores answers for unknown or stale ids. This replaces Dart's epoch fences,
   `identical(_session, …)` checks, and `Completer` chains.
5. **Records are the single output stream.** The in-memory session, Dart
   `TugboatCaptureSinkFactory` sinks, health, and the collector all consume the
   same engine records. Collector wire bodies appear only inside send effects.
6. **Preserve, then change on purpose.** The engine first reproduces Dart.
   Every deviation is listed in section 11 and lands with its own fixtures.

## 3. Message protocol

Slice 2's envelope stays. Stateful messages add a time stamp and return
records next to effects.

### Input

```json
{"type": "input.pointer", "at": {"monoUs": 81234567, "wallUs": 1791712345678901}, "input": { }}
```

- `at.monoUs`: the host monotonic clock (section 5) at the moment the fact
  happened, not when it was submitted. Required on every stateful message.
- `at.wallUs`: UTC epoch microseconds at the same moment. Required on
  `session.start`, `session.end`, `identity.set`, and `transport.result`.
  Optional elsewhere.
- `batch`: `{"type": "batch", "messages": [ … ]}` applies messages in order
  in one ABI call and returns the concatenated output. Adapters behind an
  asynchronous seam send one batch per UI frame.

### Output

```json
{"type": "input.pointer", "records": [ ], "effects": [ ]}
```

- `records`: things that happened, in append order. Each is
  `{"kind": "event" | "frame" | "health", …}`. An `event` record carries the
  same JSON as today's `TugboatEvent.toJson()`, already enriched (section 4.4).
- `effects`: things the host must do, in order (section 3.1).
- Stateless message types from slice 2 keep `result` and never emit records.

### 3.1 Effects

| Effect | Fields | Host answer |
| --- | --- | --- |
| `timer.schedule` | `timerId`, `atMonoUs` | `timer.fired {timerId}` |
| `timer.cancel` | `timerId` | none |
| `http.send` | `requestId`, `lane` (`lifecycle`, `events`, `frames`), `path`, `timeoutMs`, and either `json` (body) or `multipart` (`fields`, `frames: [{handle, filename}]`) | `transport.result` |
| `frame.release` | `handle` | none |
| `capture.request` | section 8.2 | `capture.result` |
| `outbox.write` / `outbox.remove` | section 7.8 (phase 3e) | none |

A host executes effects in order. For `timer.schedule`, an existing timer
with the same id is replaced.

`transport.result` input:
`{requestId, outcome: "http" | "error" | "timeout", status?, body?}`.
`body` is the first 64 KiB of the response; the engine parses `sessionId` and
`traitsId` from it.

## 4. Session state

### 4.1 What the engine owns

| State | Today | Notes |
| --- | --- | --- |
| Session id, `startedAt` | controller `start()` | `session-<wallUs>` from `session.start` `at.wallUs`; `startedAt` from the same value (Dart reads `DateTime.now()` twice) |
| Id counter | `_nextId` | One counter for `event-N`, `frame-N`, `capture_request-N`, `capture_execution-N`. Per engine handle and never reset per session, as today. |
| Navigator / route-instance counters | `_surfaces` | `nav-N` / `route-N` are reset per session. Adapters send opaque ids; the engine maps them (section 8.1). |
| Viewport, platform, app info, locale | `TugboatSession` | From `session.start` and `engine.configure`. |
| User id, traits, traits id | sink plus static fields | Owned by the engine. The host persists them across sessions if needed. |
| Exploration run id, action id | controller | Run id from `session.start`; the `exploration.actionWindow` action id is deferred (section 13) |
| Events, frame metadata, scroll samples | `TugboatSession` | Same limits: maxEvents 5000, maxFrames 500, 200 scroll samples, sticky `truncated`. Frame bytes stay in the host; handles are released per section 7.6. |
| Epochs and generations | controller | routeEpoch (never reset), capture generation, visual observation generation, frame completion sequence, boundary generation, pointer generation |

### 4.2 Lifecycle state machine

```text
          session.start            app.lifecycle(paused|hidden)
 idle ───────────────────► active ◄──────────────────────────► background
  ▲                          │      app.lifecycle(resumed)        │
  │                          │ session.end / detached             │
  │                          ▼                                    │
  └──────── ended ◄──── ending (drain) ◄──────────────────────────┘
```

- `session.start {viewport, platform, locale?, activationRequestId?,
  explorationRunId?, sessionEpoch}`. If a session is active, the engine ends
  it first (change C10). It then runs Dart's start sequence: cancel tap
  settles, route captures, and capture work; finalize interactions as
  `sessionEnd`; flush input observations; reset per-session state; emit
  `session_start`; request the `initial` capture.
- `app.lifecycle {state}`, where state is `paused`, `hidden`, `inactive`,
  `resumed`, or `detached`. The engine applies Dart's teardown order:
  1. tap settles;
  2. route captures;
  3. capture work;
  4. abandon pending pointers;
  5. clear released transactions;
  6. finalize gesture and scroll interactions;
  7. flush input observations.

  It emits `app_backgrounded` / `app_foregrounded` / `app_inactive` /
  `app_detached` and drops consecutive duplicates. The 500 ms background flush
  timer moves from the widget into the engine. `resumed` cancels that timer
  and requests a forced `lifecycle` capture. `detached` ends the session.
- `session.end {reason}`. Idempotent. Emits `session_end`, then drains
  delivery (section 7.7).
- After `session_end`, the engine accepts event-producing facts and drops
  them without a record, as it does before the first session (change C9). A
  batch that carries a late fact next to `session.end` is not rejected.

### 4.3 Adapter-produced events

Some evidence is entirely toolkit-produced: `scene_inventory`,
`viewport_semantic_map`, `scroll_semantic_snapshot`, `network_call`,
`external_event`, adapter `capture_diagnostic`. These arrive as
`event.record`:

`{eventType, stream, data?, targetAnchor?, atMonoUs?, attachActionContext}`

The engine mints the id and computes `atMs` from `atMonoUs` (default
`at.monoUs`). That way a `network_call` keeps its start time. The engine then
enriches and appends the event.

`locale.set {locale}` dedupes, updates the current locale, and emits
`locale_changed` while a session is active.

### 4.4 Enrichment and ordering

`_addEvent`'s rules move as they are:

- Stamp the current locale when the event has none. Interactions instead
  carry the locale captured at pointer-down.
- Stamp `captureSessionId`, `activationRequestId`, and `explorationRunId`.
  Stamp `actionId` unless `attachActionContext` is false.
- Append, emit an `event` record, then trim.

Append order is the record order. It is **not** id or `atMs` order:

- An interaction is minted at pointer-down and appended after settle.
- A `route_change` is minted at finalize.

Fixtures pin append order.

## 5. Clock model

**One host monotonic clock.** Every adapter stamps facts with the same
clock, and the engine derives all durations from it:

| Platform | Clock | Why |
| --- | --- | --- |
| Android | `SystemClock.uptimeMillis` timebase (`uptimeNanos` / 1000) | `MotionEvent.getEventTime()` uses it, so native touch facts need no conversion |
| iOS | `ProcessInfo.systemUptime` (mach absolute time) | `UIEvent.timestamp` uses it |
| Flutter (Dart) | `Stopwatch` plus an offset from `clock.sync` | Dart cannot read the host clock directly |
| React Native (JS) | `performance.now()` plus an offset from `clock.sync` | Same |

`clock.sync`:

1. When an adapter behind an asynchronous seam attaches, the host returns its
   current `monoUs`.
2. The adapter stores `hostMonoUs - localNowUs` as its offset.
3. The adapter re-syncs on every `resumed`.

Both host clocks pause in deep sleep. That matches today's Dart `Stopwatch`
behaviour on device.

Derived values:

- Event and frame `atMs`: `floor((fact.monoUs - session.startMonoUs) / 1000)`,
  matching Dart's `Stopwatch.elapsedMilliseconds`. A fact stamped before
  its session started records `0` (change C13).
- Collector `triggeredAt`: `startedAt + atMs`. This is unchanged.
- Lifecycle record `atMs`:
  - Today `session_end` uses wall-clock subtraction and can go negative
    (fixture `session-end-clock-before-start`).
  - The engine keeps the wall subtraction in the stateless
    `collector.sessionLifecycle` mapping.
  - In the stateful path it uses the monotonic difference (change C1).
- The rolling screenshot budget window and the scroll sample cadence move
  from `DateTime.now()` to the monotonic clock (change C1).

**Arrival order versus fact time.**

- The engine applies messages in arrival order and uses fact timestamps for
  values.
- Behind an asynchronous seam, a fact can arrive after a timer whose deadline
  is later than the fact's own time. For example, a `navigation` fact stamped
  1200 ms after release can arrive after the 1250 ms claim-window sweep.
- To absorb this, every window timer is scheduled `factGraceMs` late
  (config). The window comparison itself still uses fact time. Defaults:

  | Adapter | `factGraceMs` |
  | --- | --- |
  | In-process native toolkits | 0 |
  | Flutter, RN | 50 |

## 6. Configuration

`engine.configure` is sent once, before the first session. It can be sent
again between sessions.

| Group | Fields (Dart defaults) |
| --- | --- |
| `host` | app, device, ip, locale, configuredUserId (the slice 1 vocabulary) |
| `limits` | maxEvents 5000, maxFrames 500, maxScrollSamples 200 |
| `gesture` | touchSlop, panSlop, scaleSlop, trackpadScaleThreshold. These are toolkit values: Flutter uses 18 / 36 / 18 / 1.08, Android uses `ViewConfiguration`, iOS uses UIKit recognizer defaults. |
| `interaction` | claimWindowMs 1250, settleDelayMs 1000, maxReleased 8, scrollEndCaptureDelayMs 0, captureScrollSamples false, scrollCaptureIntervalMs 2000, factGraceMs |
| `navigation` | routeBarrierTimeoutMs 5000, routeStackLimit 16 |
| `capture` | budgetMs 60, budgetWindowMs 5000, degradedScale |
| `collector` | enabled, batchSize 10, flushIntervalMs 3000, maxPendingBatches 20, maxPendingEvents 60, maxPendingFrames 20, frameChunk 20, frameTimeoutMs 15000, jsonTimeoutMs 15000 (change C3), identityDebounceMs 3000, backgroundFlushDelayMs 500, endDrainTimeoutMs (change C5), reportEventLaneGaps false (change C6) |
| `capabilities` | the `TugboatReplayConfig` evidence switches (inventory, semantic map, focus, system input, …) |

## 7. Collector delivery (phase 3b)

This replaces `CollectorHttpSink` policy. The host performs requests and
reports results. The engine decides what to send, when, and what each
response means.

### 7.1 Lifecycle lane and handshake

- The lifecycle lane is a strict FIFO of `session_start`, `session_identify`,
  `traits_updated`, `user_changed`, and `session_end`. Only the head is in
  flight, and it is removed only when accepted.
- `session_start` posts with the local session id. On accept, the engine reads
  `sessionId` from the body and falls back to the local id when it is
  missing, empty, or not JSON. It caches `traitsId` from any accepted
  lifecycle response.
- Until a collector session id exists, the frames and events lanes do not
  send. Events and frames still accumulate within their bounds.
- Lifecycle bodies are built when sent, from the current user id and traits.
  `triggeredAt` is fixed when the entry is queued.
- Identity changes wait out a 3 s debounce timer and merge into one post
  (`session_identify` when both changed). While `session_start` is pending,
  the engine folds them into the start body.

### 7.2 Stamping

These rules are preserved:

| Field | Stamped |
| --- | --- |
| `userId` | when the event is recorded |
| `sessionId`, `traitsId` | when the batch is sent |

### 7.3 Flush passes

The engine models Dart's single flush pass as an explicit cursor. One request
is in flight at a time across all lanes. A pass sends, in order:

1. the lifecycle head;
2. stop if there is no collector session id;
3. pending frames, sorted by `frameNo`, in chunks of 20;
4. the retry-batch head, stopping at the first retry;
5. fresh events, in batches of ≤ 10, until the queue is empty. Events that
   arrive while the pass runs join it.

Triggers:

- the 10th pending event;
- the periodic timer (every 3 s while active);
- frame arrival, unless frames need retry;
- the background timer (500 ms after `paused`/`hidden`);
- `session.end`;
- `transport.flush` from the host, for example before process exit.

A trigger that fires during a pass sets `followUp`, which runs another pass
when this one ends (change C2). Dart drops these triggers, so late work waits
up to 3 s.

### 7.4 Response classification

| Outcome | Meaning | Dart rule |
| --- | --- | --- |
| HTTP 202 | accepted | preserved |
| 408, 429, 5xx, transport error, timeout | retry | preserved |
| any other status, including 200 / 201 / 204 | permanent drop | preserved; open question Q3 |

Retries are paced only by flush triggers: there is no backoff and no attempt
cap (change C4 proposes backoff later). Event batches retry until the
20-batch cap evicts the oldest, or until the session resets.

### 7.5 Queues and bounds

| Queue | Bound | When full |
| --- | --- | --- |
| Pending events | 60 | drop oldest |
| Retry batches | 20 batches | drop oldest |
| Pending frames | 20 | drop oldest; failed frames are requeued at the front and so go first |

Event-side drops are silent today. With `reportEventLaneGaps` (default off, change C6) the engine reports them as gap records.

### 7.6 Frames

`frame.add {handle, frame}` registers an accepted frame. `frame` is the
`TugboatFrame.toJson()` shape. In phases 3a–3c frames come from the adapter;
phase 3d replaces this with `capture.result`.

The upload is one multipart `http.send` with:

- fields `sessionId`, `frameNos`, and `frameMetadata`;
- one part per frame, named `<frameNo>.jpg`, whose bytes the host resolves
  from the handle.

Rejected-frame isolation (0.10.9) is preserved:

- A chunk that gets a retry outcome is requeued together with every later
  chunk, and frames are marked as needing retry.
- A chunk of more than one frame that gets 400 is re-sent one frame at a
  time. A single frame that gets retry requeues from its own index.
- Any other drop outcome drops the whole chunk.

Handle release (refcount):

- A handle is referenced by the delivery lane and, separately, by the
  in-memory session (up to 500 frames).
- The engine emits `frame.release` only when both references are gone: the
  frame was accepted, dropped, or evicted, and was also trimmed from the
  session or the session ended.
- Hosts keep bytes only until then.

### 7.7 Delivery gaps and session end

- Frame-lane gap diagnostics keep their wire shape:
  - `capture_diagnostic` with `component: collector_frame_upload`;
  - `result` is `failed` (latched), `recovered`, or `dropped` (reported when
    the cumulative count is 1 or a power of two).
- They become ordinary engine records, so health, factory sinks, and the
  in-memory session also see them (change C6). Their `atMs` uses the
  monotonic clock (change C1).
- Session end (change C5):
  1. `session.end` queues `session_end` but first drains frames and events
     until the lanes are empty or `endDrainTimeoutMs` passes.
  2. `session_end` keeps retrying on triggers after the periodic timer stops.
  3. Anything still undelivered when the host disposes the engine is
     reported once as a gap record.

  Today `session_end` goes first in its pass, and a failed end is never
  retried.

### 7.8 Durable outbox (phase 3e, sketch only)

The engine emits `outbox.write {key, lane, body | frameHandle}` when it
queues work and `outbox.remove {key}` when that work is accepted or dropped.
On the next launch, the host sends `outbox.restore {entries}`. The engine
re-queues them under their original session ids, sends them before the new
session's data, and applies the same bounds.

This needs an idempotency key on the wire so the collector can deduplicate
retried work (Q2). Phase 3e is deferred until Q2 is answered and is not part
of the current milestone.

### 7.9 Exploration WebSocket

It stays a host mechanism with its current queue (200 messages) and fixed
2 s reconnect. It receives the same engine records. It is a development
transport, and moving its policy into the engine buys little (Q4).

## 8. Navigation and capture coordination (phase 3d)

### 8.1 Navigation facts

The adapter maps toolkit objects to stable opaque ids and sends:

```text
navigation {kind: push|pop|replace|remove, navigatorId, parentNavigatorId?,
            route: {instanceId, name?, type, overlayKind, transitionMs},
            departing?: {instanceId, name?, type}}
```

Toolkit mappings:

| Toolkit | Source |
| --- | --- |
| Flutter | the `NavigatorObserver` callbacks |
| Android | activities and fragments, with Jetpack Navigation destinations |
| iOS | view controller appearance and container stacks |
| RN | the navigation container's state |

The engine keeps the per-navigator stacks (16 entries), the
`presentedOver` / `hostPage` logic, and the `route_change` envelope.

The route-capture work state machine moves as it is:

1. **Ignore invisible removals.**
2. **Claim the cause** before the epoch bump. The claim needs exactly one
   eligible transaction, and the navigator must match.
3. **Replace prior work on the same navigator.** Cancel it, cancel the
   waiting captures, and advance the capture generation.
4. **Start the new barrier.** Create the barrier with `++routeEpoch` and link
   `supersededBy`.
5. **Wake the claimed tap**, only once the barrier is registered.
6. **Finalize.** After `transitionMs + settleDelay`, request a `route`
   capture and emit `route_change`.
7. **Timeout.** After 5 s, emit `route_change` with
   `captureOutcome: timed_out`.

Today's `_skipCapture` is one global flag. It becomes per navigator, so
overlapping navigators no longer clear each other's suppression early
(change C11).

### 8.2 Capture protocol

The engine schedules captures. The host or adapter performs them.

```text
capture.request {requestId, trigger, force, requireFreshPaint, dropWhenBusy,
                 notBeforeMonoUs, context: {routeEpoch, navigatorId,
                 routeInstanceId, boundaryGeneration},
                 dHashBaseline, scale}
capture.result  {requestId, outcome: captured|paintUnchanged|failed|cancelled,
                 frame?: {handle, width, height, contentHash, dHash,
                          structureSignature, masked, backend…},
                 boundaryRect?, timings}
```

What the engine owns:

- The FIFO scheduler: tail absorption with trigger priority (manual >
  interaction > route > lifecycle > tap > scroll > initial), one capture in
  flight, and per-waiter resolution.
- The decision order:
  1. suppressed;
  2. budget skip;
  3. paint-unchanged reuse;
  4. dHash coalescing;
  5. exact-content reuse;
  6. `fresh_accepted`.
- Frame provenance and the compatibility predicate.
- The temporal after-frame rules.
- The budget tracker, which uses `timings` and fact time.
- Trim.

Two rules to note:

- **dHash baseline.** The engine offers it only when the adapter's
  `structureSignature` equals the last accepted structure, as today. The
  pixel runtime compares Hamming distance ≤ 2 against the baseline it was
  given and reports a match as `captured` with `dHash` equal to the
  baseline. The engine then applies `perceptual_hash_coalesced`.
- **Staleness.** The engine checks it when the result arrives. A result
  whose context no longer matches is `superseded_route_epoch`.

The adapter keeps paint-signature checks, structure signatures, masks, and
readback.

`surface {boundaryRect, generation}` reports boundary transform changes.

## 9. Interactions (phase 3c)

### 9.1 Facts

```text
input.pointer  {pointerId, phase: down|move|up|cancel, x, y,
                device: touch|mouse|stylus|trackpad, tap?}
input.panZoom  {pointerId, phase: start|update|end, x, y,
                panX?, panY?, scale?}          (update only)
scroll         {scrollableId, phase: start|update|end|overscroll, offset?,
                axis?, maxScrollExtent?, anchor?}   (overscroll: id only)
focus          {kind: text_input|other|none}
systemInput    {input: back|volume_up|volume_down|volume_mute|power|
                media_play_pause}
```

Phase 3c added `x, y` to `input.panZoom` (the contact position the end
position builds on) and `maxScrollExtent` to `scroll` (sample
`offsetNorm`), and dropped `page`, which only adapter-side semantic context
reads. The [README](../README.md) is the field-level reference.

Coordinates are logical pixels in the adapter's surface space. The engine
normalises them against the provenance of the before-frame (section 8.2).

**Tap evidence travels with the fact** (principle 2).

- On `up`, the adapter checks locally whether the pointer stayed within
  `touchSlop` of its down point. If it did, it resolves the target at the
  **down** position against the current tree and attaches `tap {anchor |
  failureReason, inventory?}`.
- In exploration mode, the adapter attaches tap evidence on the primary
  `down` instead.
- The engine re-classifies authoritatively and discards the evidence when the
  gesture is not a tap. Today's exploration path already discards evidence
  this way.

On `scroll` start the adapter attaches the scrollable's anchor. The
`scrollableId` stays stable for the scrollable's lifetime.

### 9.2 What moves into the engine

- **Gesture classification.** Single-pointer slop, the multi-pointer cluster
  (span, centroid, zoom or pan or swipe), and trackpad thresholds, all
  parameterised by `gesture` config.
- **The interaction registry.** Pending, released, and by-id; the claim
  window, the sweep, and the cap of 8; claim eligibility and `direct` /
  `delayedLikely` attribution; competing pointers; abandonment.
- **The tap-settle state machine.** Settle delay, then the remaining claim
  window measured from release, then the causal route barrier or a
  standalone `interaction` capture, then the temporal after-frame.
- **Swipe, pan, and zoom completion.** A fresh `interaction` capture with the
  after-capture fallback chain.
- **Scroll.** Trackers keyed by `scrollableId`, pairing pointer-up with
  scroll-end in either order, offsets, the overscroll count, programmatic
  scrolls (inventory only), and scroll samples.
- **Focus and system input deferral.** Publish once, after a frame with
  `completedAtMs >= atMs`, or without a frame on end, replacement, or
  background.
- **The interaction envelope and payload rules.** No before-frame means no
  positions, and `cancelled` has no payload.

### 9.3 Subtleties the implementation must keep

Each one gets a scenario fixture in the phase that can express it:

1. The claim runs before the epoch bump. The tap is woken only after the
   barrier is registered. *(Phase 3d: needs navigation. Phase 3c provides
   the claim API and the wake hook.)*
2. Pointer-cancel marks even a pending swipe `cancelled`, but abandonment
   keeps swipe and scroll gestures. *(Phase 3c.)*
3. Degraded tap observations publish immediately; others wait behind the
   serialized publish order. *(Phase 3d: in phase 3c no work outlives the
   message that started it, so every publication is immediate and the two
   orders cannot differ. The serialized order belongs to 3d's FIFO
   scheduler and route finalization.)*
4. Replacing route work on one navigator cancels **all** waiting captures,
   including tap and scroll captures. *(Phase 3d.)*
5. Teardown order on lifecycle and session events (section 4.2).
   *(Phase 3c.)*
6. Facts are applied in arrival order. Whether an `onTap` navigation arrives
   before or after its pointer-up fact decides `direct` versus
   `delayedLikely`, so each adapter must document its order. *(Phase 3d:
   needs navigation facts.)*

A known Dart defect is fixed instead of preserved (change C12):

- A scroll start links to the first pending transaction even while that
  transaction is still a tap.
- If the transaction never becomes a swipe, the scroll completion is never
  published.
- The engine instead publishes it as a `scroll` when that pointer goes up.

## 10. Conformance

A new fixture kind, `engine.scenario`, under `conformance/engine/scenario/`:

```json
{"fixtureFormat": 1, "kind": "engine.scenario", "name": "…", "description": "…",
 "contract": {"sessionSchemaVersion": 10, "fingerprintSchemaVersion": 6},
 "input": {"configure": { }, "steps": [{"send": { }, "expect": {"records": [ ], "effects": [ ]}}]},
 "expected": {"finalSnapshot": { }}}
```

- Every step's `send` carries `at`, so a scenario is fully deterministic.
- `expect` is compared type-strictly, as in slice 1. Effect order matters.
- `session.snapshot` returns the in-memory session JSON (schema 10) for
  `finalSnapshot`.
- A scenario that encodes a section 11 change carries
  `"engineOnly": ["C5"]`, listing the change ids. The Dart runner skips it;
  the C++ runner runs every scenario. `engineOnly` is valid only on
  `engine.scenario`, and its ids must be section 11 ids, listed once in
  `conformance/change_ids.json` for both runners.
- `"runners": ["cpp"]` (default both) limits a scenario to the C++ runner
  without claiming a section 11 change. Phase 3c and 3d scenarios use it
  where Dart cannot be driven (below). `engineOnly` implies it.
- Until phase 3d the Dart runner compares event ids by order of first
  appearance. Since phase 3c the engine mints `capture_request-N` for
  interaction and input-observation captures, but Dart's counter also mints
  them for captures the engine does not request before 3d (the `initial`
  capture at session start, `lifecycle` on resume, route captures) and mints
  `capture_execution-N`. **Phase 3d must switch the Dart runner to exact id
  comparison.** The C++ runner always compares exact ids.

How Dart stays in step, by phase:

| Phase | Dart side |
| --- | --- |
| 3a session, 3b delivery | A Dart scenario runner drives `CollectorHttpSink` and the session model with a fake HTTP client and `fake_async`. Both implementations run every delivery scenario in CI. |
| 3c interactions, 3d navigation and capture | The controller's `atMs` `Stopwatch` cannot be injected, and the logic is spread across widgets and futures. Scenarios are written from the existing Dart characterization tests (`replay_coherence_*`, `scroll_attribution_test`, `exploration_pre_tap_test`, `structure_aware_coalesce_test`) and gate only the C++ engine. |

Flutter gets parity for 3c and 3d by moving onto the engine behind an opt-in
backend flag (Q1).

## 11. Deliberate behaviour changes

Each change was decided on 2026-10-12. "Wire" means the collector sees a
difference. Every change applies to the engine only; Dart keeps shipped
behaviour, and scenarios that encode a change are `engineOnly` (section 10).

| Id | Change | Today | Wire | Decision |
| --- | --- | --- | --- | --- |
| C1 | One monotonic clock for all durations | Wall clock for `session_end` `atMs`, gap `atMs`, budget window, scroll cadence | small: `atMs` can no longer go negative | Yes |
| C2 | A flush trigger during a pass schedules a follow-up pass | Trigger dropped; up to 3 s extra latency | timing only | Yes |
| C3 | Timeout on JSON posts | None; one hung request stalls all delivery | no | Yes, `jsonTimeoutMs` 15000 |
| C4 | Exponential retry backoff with jitter | Retries paced only by flush triggers | timing only | Later, after the durable outbox |
| C5 | `session_end` waits for a bounded drain and keeps retrying | `session_end` goes first; never retried after failure | order: frames/events no longer arrive after `session_end` | Yes |
| C6 | Delivery gaps become engine records; event-lane drops can also report gaps | Frame lane only; invisible to other sinks | new `component` values | Records: yes. Event-lane gaps: opt-in, default off |
| C7 | Per-engine id counter and non-contiguous `frameNo` | as stated | no | Keep (no change) |
| C8 | 202-only acceptance | 200/201/204 count as drops | no | Keep (Q3) |
| C9 | Drop (no record) events after `session_end` | Events can follow `session_end` | yes, removes stray events | Yes (engine-only; approved by local orchestrator 2026-10-12) |
| C10 | `session.start` on an active session ends it first | `clear()` replacement emits no `session_end` (test-only path) | yes | Yes |
| C11 | Per-navigator transition suppression | One global `_skipCapture` | fewer `route_transition` drops | Yes |
| C12 | Publish a linked scroll when a still-tap pointer goes up | Completion never published | yes, recovers lost scrolls | Yes |
| C13 | Facts stamped before session start record `atMs` 0 (async-seam skew) | Cannot happen (Dart stamps on arrival) | small: no negative `atMs` | Yes (engine-only; approved by local orchestrator 2026-10-12) |
| C14 | The pointer tracker forgets every contact on every teardown cause (session end and replacement too) | The widget resets `InputCapture` on `paused`/`hidden`/`detached` only, so a contact held across a session boundary can join the next session's gesture | small: a stale contact can no longer absorb a new pointer | Yes (engine-only; decided during the phase 3c review 2026-10-12) |

## 12. Open questions and decisions

All five were decided on 2026-10-12.

- **Q1: Flutter migration timing.** Flutter moves onto the engine after phase
  3d, behind an opt-in backend flag, in a later milestone. There is no
  delivery-only mode.
- **Q2: Wire idempotency.** Deferred. The durable outbox and safe retries
  need an idempotency key per batch, frame, and lifecycle post, which needs a
  collector change and a cross-repo decision. Phase 3e is out of the current
  milestone; native hosts deliver from memory, like Flutter does today.
- **Q3: Non-202 success codes.** Keep 202-only acceptance (C8).
- **Q4: Exploration WebSocket policy.** It stays host-side. Native SDKs do not
  need it in the current milestone.
- **Q5: In-memory session ownership.** Limits stay config-driven with today's
  defaults. Native SDKs do not need snapshot export, so native hosts may pass
  smaller limits later.

## 13. Phases

Each phase is one PR into `adr-0009-shared-engine`, with its own scenario
fixtures:

| Phase | Scope |
| --- | --- |
| 3a | Stateful protocol (`at`, `batch`, records, timers); `engine.configure`; session state and lifecycle; `event.record`, `locale.set`, enrichment, trim; `session.snapshot`; the `engine.scenario` kind with a C++ runner and a Dart runner for the session model |
| 3b | Collector delivery (section 7.1–7.7), with Dart parity scenarios for `CollectorHttpSink` |
| 3c | Interactions (section 9) |
| 3d | Navigation and capture coordination (section 8) |
| 3e | Durable outbox (section 7.8). Out of the current milestone; waits for Q2 |

Deferred beyond this milestone: the exploration action window
(`exploration.actionWindow`, `action_window_set` / `action_window_cleared`,
and `actionId` stamping). Native SDKs do not use exploration.

After 3d:

- the Android host links the engine (slice 4);
- Flutter gets the opt-in engine backend (slice 5).
