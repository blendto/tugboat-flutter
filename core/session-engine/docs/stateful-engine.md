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
  `session.start`, `session.end`, `identity.set`, `traits.set`, and
  `transport.result`. Optional elsewhere.
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
| `http.send` | `requestId` (string, `http-N`), `lane` (`lifecycle`, `events`, `frames`), `path`, `timeoutMs`, and either `jsonBody` (the body, already encoded) or `multipart` (`fields`: ordered `[name, value]` string pairs; `frames: [{handle, filename}]`) | `transport.result` |
| `frame.release` | `handle` | none |
| `capture.request` | section 8.2 | `capture.result` |
| `outbox.write` / `outbox.remove` | section 7.8 (phase 3e) | none |

Every `http.send` also arms `delivery.answer.<requestId>` at `timeoutMs +
answerGraceMs`: without a `transport.result` by then, the engine treats the
request as timed out and ignores a late answer (change C15).

`engine.dispose {}` (`at` optional) is the host's last message before
`tb_session_engine_destroy`, sent between sessions (a live session is ended
first). The engine reports undelivered work (section 7.7), releases every
frame it still references, and then admits no further command.

A host executes effects in order. For `timer.schedule`, an existing timer
with the same id is replaced.

`http.send` carries the exact wire bytes of a JSON body as the string
`jsonBody` (byte-identical to Dart's `jsonEncode`), so hosts never re-encode
it. Multipart fields are ordered pairs, because the field order is part of
the request. All values are strings. Headers (API key, app identity,
content type) are the host's.

`transport.result` input:
`{requestId, outcome: "http" | "error" | "timeout", status?, body?, retryAfter?}`.
`requestId` echoes the effect's string id. `status` comes with `http` only.
`body` is the first 64 KiB of the response; the engine parses `sessionId` and
`traitsId` from it. `retryAfter` is the `Retry-After` header value and is only
allowed with `outcome: "http"`; hosts send it whenever the response carries the
header (any status), trimmed of ASCII whitespace and at most 128 UTF-8 bytes.
The engine keeps it raw on decode and trims ASCII whitespace and checks the
128-byte bound once, when it parses it. Values longer than 128 bytes after
trim are dropped by hosts and ignored by the engine (they never invalidate
the delivery result). Strict decoding still rejects a non-string
`retryAfter` or one paired with a non-`http` outcome (host bugs).

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

#### 4.3.1 External events and network calls

Native hosts do not build `external_event` and `network_call` data
themselves. They send the raw facts, and the engine applies Flutter's
parameter policy, limits, label bounding, method and route normalization,
error-body normalization, and duration arithmetic, written once in C++:

| Message | `at` | Input | Records |
| --- | --- | --- | --- |
| `evidence.externalEvent` | mono | `{name, source?, policy {mode, allowedKeys?}, parameters?, atMonoUs?}` | `external_event` on the evidence stream, data `{source?, name, parameterKeys, parameters?, capture}` |
| `evidence.networkCall` | mono | `{method, route, startMonoUs, endMonoUs?, statusCode?, outcome, attemptCount?, errorResponseBody?}` | `network_call` on the evidence stream at `startMonoUs` (C19), data `{method, route, statusCode?, outcome, durationMs, attemptCount?, errorResponseBody?, errorResponseBodyCapture?}` |

Both are event-producing and never inherit an action context. An invalid
name, method, or route, or a call that began before the live session,
records nothing, as Dart's recorder records nothing. Parameter values and
error bodies use a typed value encoding. The encoding, the engine rules,
and the host obligations (transform closure, typed conversion, map order,
elision) are in [evidence-messages.md](evidence-messages.md).

Dart's evidence health counters (`TugboatEvidenceHealth`) are only read
through the local `TugboatReplay.health` API and never reach the wire, so
the engine does not mirror them.

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
| `capture` | budgetMs 60, budgetWindowMs 5000, degradedScale, answerTimeoutMs 5000 (change C18) |
| `collector` | enabled, batchSize 10, flushIntervalMs 3000, maxPendingBatches 20, maxPendingEvents 60, maxPendingFrames 20, frameChunk 20, frameTimeoutMs 15000, jsonTimeoutMs 15000 (change C3), identityDebounceMs 3000, backgroundFlushDelayMs 500, endDrainTimeoutMs 5000 (change C5), reportEventLaneGaps false (change C6), answerGraceMs 5000 (change C15), maxRetryAfterMs 60000, maxEndingRetryAfterMs 10000 |
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

Retries are paced by flush triggers and by `Retry-After` waits on 429/503:
there is no backoff and no attempt cap (change C4 proposes backoff later).
Event batches retry until the 20-batch cap evicts the oldest, or until the
session resets.

When a lane receives HTTP 429 or 503 with a parseable `retryAfter` on
`transport.result`, that lane does not send again before
`now + min(parsed, collector.maxRetryAfterMs)` (default 60 s); other lanes are
unaffected. The engine arms `delivery.retryAfter.<lane>`; a flush while the lane
waits skips that lane. A newer `Retry-After` replaces the older not-before.
Unparseable values and other retry statuses keep today's timing.

Each pass checks a lane's wait once, where that lane's stage starts. A wait
armed by a response during the pass stops that lane for the rest of the pass:
fresh events not yet sent stay in the fresh queue (they never become retry
batches unsent, so `maxPendingBatches` evicts only batches that were sent).
The events and frames lane timers start one pass. The lifecycle lane timer
drains the lifecycle lane, as `delivery.identity` does: the head is sent and,
each time it is accepted, the next queued post follows. So a `session_end`
queued behind a waiting head goes out right after it. The Flutter sink does
the same (`_drainLifecyclePosts` after the lane timer), subject to existing
C15 dispose and host `stop()` bounds.

From `session.end` until the next `session.start` (phases draining and ended;
in Flutter, from `endSession` until `startSession`), lifecycle-lane
`Retry-After` waits are capped at `collector.maxEndingRetryAfterMs` (default 10
s) so `session_end` can still complete within host `stop()` watchers (≤ 25 s):
`session.end` shortens a longer lifecycle wait already running to that cap,
and a 429/503 received meanwhile waits at most that long. Other lanes keep the
normal `maxRetryAfterMs` cap. Host watchers that wait ≤ 25
s for `session_end` to settle can still time out when a non-lifecycle lane waits
longer; classify rules are unchanged so engine retry-classification tests still
apply.

### 7.5 Queues and bounds

| Queue | Bound | When full |
| --- | --- | --- |
| Pending events | 60 | drop oldest |
| Retry batches | 20 batches | drop oldest |
| Pending frames | 20 | drop oldest; failed frames are requeued at the front and so go first |

Event-side drops are silent today. With `reportEventLaneGaps` (default off, change C6) the engine reports them as gap records.

### 7.6 Frames

Frames have one entry path: a `captured` `capture.result` (section 8.2)
that the capture seam accepts as `frame-N`. Delivery observes every accepted
frame through a frame acceptance hook in the module registry and queues it;
`capture.result` rejects a frame whose `requestedBackend` or
`resolvedBackend` is outside the collector's closed vocabulary
(`flutterRepaintBoundary`, `nativeCpuExperimental`).

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
- Hosts keep bytes only until then. A captured frame nothing accepts (an
  unknown or invalidated request, or no live session) is released at once.
- A handle in a message the engine rejects (for example a `capture.result`
  with a backend outside the vocabulary) never reaches the engine: no
  `frame.release` follows, and the host keeps owning it.

### 7.7 Delivery gaps and session end

- Frame-lane gap diagnostics keep their wire shape:
  - `capture_diagnostic` with `component: collector_frame_upload`;
  - `result` is `failed` (latched), `recovered`, or `dropped` (reported when
    the cumulative count is 1 or a power of two).
- They become ordinary engine records, so health, factory sinks, and the
  in-memory session also see them (change C6). Their `atMs` uses the
  monotonic clock (change C1). After `session_end` they are still records
  and still delivered, but the closed in-memory session takes no more
  events.
- Event-lane gaps (opt-in, `reportEventLaneGaps`): `capture_diagnostic`
  with `component: collector_event_upload`, `result: dropped`, `reason`
  (`evicted` from the pending or retry queue, or `rejected` by a permanent
  drop status), `statusCode?`, `eventCount`, and the cumulative
  `droppedEventCount`, reported each time the cumulative count crosses a
  power of two. Evictions caused by queueing a gap event are counted, not
  reported.
- Session end (change C5):
  1. `session.end` queues `session_end` but first drains frames and events
     until the lanes are empty or `endDrainTimeoutMs` passes.
  2. `session_end` keeps retrying on triggers after the drain; the periodic
     timer keeps running until every lane is empty, then stops.
  3. Anything still undelivered when the host disposes the engine is
     reported once as a gap record. The host sends `engine.dispose {}`
     (section 3) before `tb_session_engine_destroy`; the engine reports and
     becomes inert. A new `session.start` that resets delivery reports what
     it discards the same way. The report is a `health` record
     (`component: collector_delivery`) with counters `undelivered*` (queued:
     never sent, or waiting for a retry) and `inFlight*` (the request whose
     answer is still pending, such as a replaced session's `session_end`),
     each for `Lifecycle`, `Events`, and `Frames`.

  `session_end`'s `triggeredAt` and `atMs` are the `session.end` fact's
  time, not the time the drain ended.

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

The adapter maps toolkit objects to stable opaque ids and sends (anchors
it attaches anywhere may name their `toolkit`, section 9.1):

```text
navigation {kind: push|pop|replace|remove|session_start, navigatorId,
            parentNavigatorId?,
            route?: {instanceId, name?, type, overlayKind, transitionMs},
            departing?: {instanceId, name?, type?},
            routes?: [{instanceId, name?, type, overlayKind, transitionMs}, …]}
```

`session_start` seeds the visible stack at session start (Flutter
`navigation: session_start`). It requires non-empty `routes` (bottom to
top); each `transitionMs` must be `0`; `route` and `departing` must be
absent. Any other kind must not send `routes`. The engine replays the stack
like Flutter's retained-route replay: no claim, barrier, transition timers,
or route capture; it records one `route_change` with `navigation:
session_start`, `result: unknown`, no `fromRoute` / `fromRouteName` /
`fromRouteType` / `fromRouteNamed` (the seeded replay does not set
`previous_route` or `from`), `fromRouteInstanceId` when the seeded stack has
a route below the top (same as Flutter `asSessionStartWireChange`), and
`navigationOrigin: automatic_or_unknown`. Outside a live session the fact is
dropped like every event-producing fact. A seed is accepted and dropped
with no record (it does not poison a batch, and the visible route is
unchanged) when either:

- the session has already had a live navigation (any `push`, `pop`,
  `replace`, or `remove` that is not an invisible removal), whatever the
  seed's navigator; the seed then mints no navigator; or
- its navigator already has a stack in the current session.

Adapters may send seeds in any order; a child seed may precede its parent
(`NavigatorRegistry::navigator` mints the parent with an empty stack, so the
parent's own seed is still accepted). The last seed's top route is the
visible route; adapters send the visible chain last. Each nested navigator
still sends one `session_start`. Each recorded `session_start` re-stamps the
session's `initial` capture context (queued, in flight, or already accepted)
to the newly visible route so the first tap has a compatible before-frame,
matching Flutter's outcome when `seedSessionStartRoute()` runs before the
initial capture request. A live navigation re-stamps nothing: an `initial`
capture requested before it keeps the route context it had (the last
seed's, or none) and is stale because its route epoch is older, as in Dart.

`route` is the destination: the pushed route, the replacement, or the route
a pop or removal reveals; it is absent when none is (Dart's `previousRoute`
can be null). `departing` names the route leaving or covered; only its id is read (it
finds the stack entry). `name` and `type` are validated but not read:
`route_change`'s `from*` fields come from the visible route, as in Dart,
which has none for a session's first navigation. Every adapter knows its
navigator, so `navigatorId` is required and Dart's unbound-navigator path
has no counterpart. A navigator first named as a parent is numbered right
after its child, as Dart's `idForNavigator` does; its own parent is learned
from its first fact that names one.

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
(change C11). A capture is suppressed while the navigator its request
context names (the visible navigator) is in a transition, from that
navigator's navigation with `transitionMs > 0` until its route deadline.

Asynchronous Dart work maps onto two engine mechanisms:

- **Deferred work.** A capture answer or a done route barrier resumes its
  waiter after the command that produced it (Dart: a microtask), so the
  waiter sees the state that command leaves, such as the route that
  superseded its capture.
- **The publication queue** (Dart `_queue`). Route finalization, settled
  taps with a frame, and completed gestures publish in order; a route
  finalize holds the queue until its route is done (section 9.3 #3).

### 8.2 Capture protocol

The engine schedules captures. The host or adapter performs them.

```text
capture.request {requestId, trigger, force, requireFreshPaint, dropWhenBusy,
                 notBeforeMonoUs, context: {routeEpoch, navigatorId,
                 routeInstanceId, boundaryGeneration},
                 dHashBaseline?: {dHash, structureSignature}, scale}
capture.result  {requestId, outcome: captured|paintUnchanged|failed|cancelled,
                 frame?: {handle, width, height, contentHash, dHash?,
                          structureSignature?, masked, backend…,
                          maskCoverage?: {mode, reasons}},
                 boundaryRect?, failure?, timings?}
```

- `requestId` names one physical capture (`capture-N`, its own counter).
  The logical requests it serves keep Dart's `capture_request-N` ids, and
  each execution's `capture_execution-N` is minted when it resolves, so the
  shared id counter advances exactly as Dart's does.
- The engine waits out each request's not-before time itself (timer
  `capture.due`), so a later compatible request can still join it, as in
  Dart's pump. `notBeforeMonoUs` has passed when the host sees the request.
- `force` is Dart's attempt-level force (`force || freshPaint || no
  compatible frame`): a forced request never answers `paintUnchanged` and
  gets no baseline. `dropWhenBusy` is informative; the engine already
  applied it.
- `failure` names why a `failed` capture produced no frame (Dart
  `ScreenshotCaptureFailure`, plus `secureWindow`). `timings`
  (`frameWaitMicros`, `readbackMicros`, `maskMicros`, `encodeMicros`) feed
  the budget.
- `maskCoverage` (native hosts) says which mask mode applied to the frame:
  `mode` is `precise` (individual regions), `wholeHost` (a toolkit host
  view masked whole, the Compose default), or `wholeFrame`; `reasons` is
  an array of at most 8 distinct names from a closed set
  (`composeDefault`, `composeVersionUnverified`, `composeOwnerUnavailable`,
  `interop`, `regionUnreadable`, `treeUnreadable`, `animating`,
  `unverifiedLayerAllowlist`, `walkExhausted`, `noWindowSize`, `noDecor`,
  `representable`, `webView`, `renderer`, `surfaceLayer`,
  `unclassifiedLayer`, `secureText`, `overlayWindow`: every value the
  Android and SwiftUI adapters emit), possibly empty. An unknown value is
  `invalid_message` and the host keeps the handle. When the engine accepts the frame it records
  `capture_diagnostic` `{component: capture_masking, frameId, mode,
  reasons}` right after the frame record, before the frame-accepted hooks
  run (so a delivery eviction gap follows it), always (with or without the
  `captureDiagnostics` capability), so a whole-masked host can be told
  from a broken capture. The frame record and `frameMetadata` never carry
  it. A frame without `maskCoverage` (Flutter, older hosts) records nothing
  new; a frame the engine reuses, coalesces, or releases records nothing.
- Change C21: exact-content reuse also needs the retained frame's
  `maskCoverage` to match: the same `mode` and the same set of `reasons`
  (absent matches only absent). A frame with the same pixels but other
  masking provenance (an `overlayWindow` frame over an unchanged screen,
  or the first frame after the overlay is gone) is accepted as a new frame
  and records its own `capture_masking`. Coalescing is unchanged: it
  compares the host's `structureSignature`, so a host whose coverage
  changes identity folds it into that token (Android adds an overlay token
  while `overlayWindow` is reported).
- `secureWindow`: a native host never copies a window flagged secure
  (Android `FLAG_SECURE`). It resolves as `capture_processing_failed`, like
  the other non-retryable failures, and its `capture_diagnostic` carries
  `failure: secure_window`. It is not a host contract failure. Without the
  `captureDiagnostics` capability it is still recorded, but throttled: only
  the first secure window of each route instance in a session (the session
  before any route counts as one). Later ones are counted, and each
  teardown (background, session end or replacement) records one
  `capture_diagnostic` `{component: capture_secure_window,
  routeInstanceId?, repeatCount}` per route instance with repeats since
  the last report. A secure screen captured on every interaction therefore
  costs at most one diagnostic per route instance plus one per teardown.
- The host answers every request exactly once, by id. It must not
  assume one request at a time: teardown abandons the capture in flight
  (change C16), so a new `capture.request` can arrive while the host still
  performs an earlier one. A late answer to an abandoned id is ignored and
  its frame released.
- Change C18: a request unanswered `capture.answerTimeoutMs` (default
  5000) after it was issued (timer `capture.answer.<requestId>`) resolves
  as `paint_readiness_timeout`; its `capture_diagnostic` carries `failure:
  answer_timeout` and is recorded even without the `captureDiagnostics`
  capability. A late answer to that id is ignored and its frame released.
  A `paintUnchanged` answer to a forced request breaks the contract too: it
  resolves as `capture_processing_failed` with `failure:
  contract_violation`, always recorded.

What the engine owns:

- The FIFO scheduler: tail absorption with trigger priority (manual >
  interaction > route > lifecycle > tap > scroll > initial), one capture in
  flight, and per-waiter resolution.
- The decision order:
  1. suppressed;
  2. budget skip;
  3. paint-unchanged reuse;
  4. dHash coalescing;
  5. exact-content reuse (same mask coverage, change C21);
  6. `fresh_accepted`.
- Frame provenance and the compatibility predicate.
- The temporal after-frame rules.
- The budget tracker, which uses `timings` and fact time.
- Trim.

Two rules to note:

- **dHash baseline.** The engine cannot know the next capture's structure
  before it is made, so it sends the last accepted dHash together with the
  structure it was captured with. The adapter offers the baseline to its
  pixel runtime only when its current `structureSignature` equals that one,
  as today. The pixel runtime compares Hamming distance ≤ 2 against the
  baseline and reports a match as `captured` with `dHash` equal to the
  baseline. The engine applies `perceptual_hash_coalesced` only when both
  the dHash and the structure equal the offered baseline.
- **Staleness.** The engine checks it before it asks the host and when the
  result arrives. A context whose route epoch, route, or boundary
  generation changed, or a capture generation advanced by navigation or
  teardown, is `superseded_route_epoch`.
- **Paint-unchanged retry.** Dart retries a paint-unchanged attempt once,
  forced, when no compatible frame is left to reuse. With one capture in
  flight the latest frame cannot change before the answer, so the engine
  has no retry.

The adapter keeps paint-signature checks, structure signatures, masks, and
readback.

`surface {boundaryRect, generation}` reports boundary transform changes:
`generation` is the adapter's boundary transform generation (Dart
`_boundaryTransformGeneration`). The engine's observed boundary is the
latest `surface` rect, or the `boundaryRect` of the latest accepted frame.

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

An anchor from a native adapter may carry `toolkit`: `view`, `compose`,
`swiftui`, `uikit`, or `react-native` (a closed set; anything else is
`invalid_message`). It is evidence, never a fingerprint input. The engine
passes it through unchanged into event records and into every collector
`targetAnchor`, the interaction's reduced anchor included, as the last key.
Flutter anchors carry none, so Flutter output is unchanged.

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
   serialized publish order. *(Phase 3d decided: the serialized order is
   kept, as in Dart. A route finalize holds the publication queue until its
   route is done; settled taps with a frame and completed gestures publish
   through that queue; a degraded tap observation publishes at once.
   Fixture `navigation-publication-order`.)*
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
- Both runners compare exact ids (since phase 3d). The engine mints
  `capture_request-N` and `capture_execution-N` where Dart does: the
  `initial` capture at session start, the `lifecycle` capture on resume,
  and one execution id per request a teardown cancels. The Dart runner does
  not compare `capture.request` effects: its capture scheduler is held
  async work. Before the first session Dart mints an id for a dropped
  `app.lifecycle` event and the engine does not, so
  `app-lifecycle-before-first-session` runs on the C++ runner only.

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
| C5 | `session_end` waits for a bounded drain and keeps retrying | `session_end` goes first. Before 0.10.11-dev.5 it was never retried after failure; Flutter 0.10.11-dev.5+ re-posts a retried `session_end` on the periodic flush (`eventFlushInterval`) until it is accepted or dropped (a dropped one is settled, as the native `SessionEndWatcher.isFinal`), then stops the flush; there is no events/frames drain | order: frames/events no longer arrive after `session_end` | Yes |
| C6 | Delivery gaps become engine records; event-lane drops can also report gaps | Frame lane only; invisible to other sinks | new `component` values | Records: yes. Event-lane gaps: opt-in, default off |
| C7 | Per-engine id counter and non-contiguous `frameNo` | as stated | no | Keep (no change) |
| C8 | 202-only acceptance | 200/201/204 count as drops | no | Keep (Q3) |
| C9 | Drop (no record) events after `session_end` | Events can follow `session_end` | yes, removes stray events | Yes (engine-only; approved by local orchestrator 2026-10-12) |
| C10 | `session.start` on an active session ends it first | `clear()` replacement emits no `session_end` (test-only path) | yes | Yes |
| C11 | Per-navigator transition suppression: a capture is suppressed while the navigator of its request context is in its own transition, until that navigator's route deadline | One global `_skipCapture`, which another navigator's navigation or deadline clears early, so Dart can capture mid-transition | more `route_transition` drops than Dart for overlapping navigators; never a capture during the requesting navigator's own transition (a frame taken mid-transition is worse than a dropped one) | Yes (engine-only; approved by local orchestrator 2026-10-12) |
| C12 | Publish a linked scroll when a still-tap pointer goes up | Completion never published | yes, recovers lost scrolls | Yes |
| C13 | Facts stamped before session start record `atMs` 0 (async-seam skew) | Cannot happen (Dart stamps on arrival) | small: no negative `atMs` | Yes (engine-only; approved by local orchestrator 2026-10-12) |
| C14 | The pointer tracker forgets every contact on every teardown cause (session end and replacement too) | The widget resets `InputCapture` on `paused`/`hidden`/`detached` only, so a contact held across a session boundary can join the next session's gesture | small: a stale contact can no longer absorb a new pointer | Yes (engine-only; decided during the phase 3c review 2026-10-12) |
| C15 | Engine-side answer deadline: an `http.send` without a `transport.result` by `timeoutMs + answerGraceMs` (default 5000) is a timeout; a late answer is ignored | A hung request is bounded by the `http` client only | no (timing only) | Yes (engine-only; decided during the phase 3b review 2026-10-12) |
| C16 | Teardown abandons the capture in flight instead of awaiting it: the next `capture.request` may be issued while the host still performs the abandoned one, whose late answer is ignored (frame released) | The scheduler waits for the platform capture to finish before the next one | no (an id gap: no late `capture_execution-N` for the abandoned capture) | Yes (engine-only; approved by local orchestrator 2026-10-12) |
| C17 | Navigator and route-instance ids are per session | A route object keeps its `route-N` across sessions (`Expando`) while the counter restarts, so ids can collide | yes: `routeInstanceId` of a route seen in an earlier session | Yes (engine-only; approved by local orchestrator 2026-10-12) |
| C18 | Capture answer deadline: a `capture.request` unanswered `capture.answerTimeoutMs` (default 5000) after it was issued resolves as `paint_readiness_timeout` with `capture_diagnostic` `failure: answer_timeout` (always recorded); a late answer is ignored (frame released) | No deadline (the frame wait times out on the UI thread) | yes: a route or interaction whose capture the host dropped is recorded without a frame instead of never | Yes (engine-only; approved by local orchestrator 2026-10-12) |
| C19 | A `network_call` from `evidence.networkCall` is stamped with the call's start (`startMonoUs`) | Dart stamps `atMs` when the call finishes | yes: `triggeredAt` of native network calls is the request start | Yes (engine-only; decided by the ADR 0009 orchestrator for native evidence 2026-10-16) |
| C21 | Exact-content reuse requires the retained frame's `maskCoverage` (mode and reason set) to equal the answer's; otherwise the answer is accepted as a new frame and records `capture_masking` | Dart has no `maskCoverage`: reuse matches `contentHash` only | yes: native hosts get a new frame (and `capture_masking`) when masking provenance changes over unchanged pixels, e.g. `overlayWindow` | Yes (engine-only; decided by the ADR 0009 orchestrator for W6a, PR #119, 2026-10-23) |

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
