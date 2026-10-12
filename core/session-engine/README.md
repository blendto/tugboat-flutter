# C++ session engine

The I/O-free, single-threaded session engine from
[ADR 0009](../../docs/decisions/0009-shared-session-engine.md). Its public
surface is a versioned C ABI (`include/tugboat/tb_session_engine.h`). A
platform host (Kotlin, Swift) owns one engine handle, submits facts as
messages, and executes the records and effect requests the engine returns.

The engine implements the stateless operations that the
[conformance fixtures](../../conformance/README.md) pin (fingerprint hashing
and collector record mapping) and the stateful session core described below.
It reproduces the current Dart implementation except for the deliberate
changes listed in section 11 of the [stateful design](docs/stateful-engine.md).
Like `core/image-processing`, it is never copied into a pub package; it
ships inside the platform runtimes (ADR 0003).

## Layout

```text
core/session-engine/
  include/tugboat/tb_session_engine.h   public C ABI (no C++ types)
  src/                                  engine (C++17, internal headers)
  tests/tb_session_engine_test.cpp      unit tests (internals + ABI error paths)
  tests/tb_session_engine_stateful_test.cpp  unit tests (timers, teardown, lifecycle)
  tests/tb_session_engine_interaction_test.cpp  unit tests (classifier, registry, ledger, claims)
  tests/tb_session_engine_conformance.cpp  fixture runner (public ABI only)
  tests/conformance/                    runner JSON reader, diff, scenario runner
  fuzz/message_fuzz.cpp                 libFuzzer target for submit
  docs/stateful-engine.md               accepted stateful design
  third_party/double-conversion/        vendored, see "Third-party code"
```

`src/` modules:

| Module | Owns |
| --- | --- |
| `tb_session_engine.cpp` | The C ABI: handles, buffers, status codes, error documents. |
| `engine` | Envelope validation, `batch`, admission, and response documents. |
| `module_registry` | What modules contribute: message types (with their `at` rule and session policy), teardown work per stage, timers by id prefix, lifecycle hooks, frame-accepted hooks, event record observers (which the recorder reaches through the dispatcher's `EngineState::applying`, with the message's `at`), and the event types the engine records itself. |
| `modules` | Registers every `*_module.cpp` once (`register_*_module`). |
| `engine_module.cpp` | `engine.configure`, `engine.dispose`, `session.snapshot`, `timer.fired`. |
| `session_module.cpp` | `session.start`, `session.end`, `app.lifecycle`. |
| `evidence_module.cpp` | `event.record`, `locale.set`. |
| `identity_module.cpp` | `identity.set`, `traits.set`: the runtime user id and the traits bag, with change detection. |
| `frame_retention`, `frame_retention_module.cpp` | Who references each accepted frame: the session (taken and trimmed by the capture seam, dropped at session end) and delivery; `frame.release` once both let go (design section 7.6). |
| `stateless_module.cpp` | The stateless operations (`fingerprint.cpp`, `collector.cpp`). |
| `collector_mapping` | The one collector wire mapping (`collector_mapper.dart`), shared by the stateless operations and delivery. |
| `delivery_module.cpp` | Collector delivery (design section 7): `transport.result`, `transport.flush`, the `delivery.` timers, hooks, and observers. Its state is `delivery_state.h`; the parts below each hold one concept. |
| `delivery`, `delivery_lanes`, `flush_pass` | Delivery phases, triggers, identity, and the session end drain; queueing events and frames, gaps, and release; the flush pass cursor and response handling (`flush_cursor.h` holds its state). |
| `lifecycle_lane`, `event_queue`, `frame_lane`, `delivery_gaps`, `delivery_bounds`, `transport` | The `/v1/sessions` FIFO, the identity debounce that feeds it, and the handshake; pending events and retry batches with send-time stamping; pending frames and the multipart body; gap thresholds; every queue bound and its eviction rule; `transport.result` and its classification. |
| `navigation_module.cpp` | Navigation and capture (design section 8), with its state header. |
| `interaction_module.cpp` | Interactions (design section 9): the interaction messages, `interaction.` timers, and teardown stages. Its state is `interaction_state.h`; the parts below each hold one concept. |
| `gesture_classifier` | Pure classification: touch slop, the multi-pointer cluster, trackpad thresholds, from the `gesture` config. |
| `pointer_tracker` | Contacts, the cluster, and the trackpad contact (Dart `InputCapture`); turns facts into controller signals. |
| `pointer_interactions` | The controller's pointer entry points: pointer-down/up/cancel, marks, absorption, abandonment. |
| `interaction_transaction`, `interaction_registry` | One gesture's transaction and its explicit stages; the pending/released/by-id registry with claim eligibility, sweep, and cap. |
| `tap_settle` | A tap after pointer-up: the claim window (sweep timer, cap) and the tap-settle state machine. |
| `scroll_interactions` | Scroll trackers, samples, and pointer-up/scroll-end pairing. |
| `input_observations` | Focus and system-input events that wait for one frame. |
| `tap_evidence`, `interaction_payload` | Tap evidence on facts; the interaction schema 2 envelope and payload. |
| `interaction_publish` | Publishing and early finalization, the temporal after-frame rules, and swipe/pan/zoom completion. |
| `interaction_facts` | Typed interaction facts and the `capture.result` decoder. |
| `capture_seam` | The capture seam (`EngineState::captures`): outstanding `capture.request`s and their owners, frame acceptance, and frame provenance. Phase 3d replaces its implementation with the capture scheduler behind the same interface. |
| `interaction_claims` | What navigation (phase 3d) calls: the claim API, the settle wake hook, and the route stamp. |
| `engine_state.h` | Everything a handle holds between messages, as plain data. |
| `config` | The typed `engine.configure` configuration. |
| `lifecycle` | The lifecycle state machine, app-lifecycle mapping and dedupe, admission. |
| `clock` | `at`, `atMs` derivation, and host timer deadlines. |
| `teardown` | The ordered teardown stages. |
| `session` | The in-memory session (events, frames, scroll samples), the id counter, and the schema 10 snapshot. |
| `recorder` | Enrichment and append (Dart `_addEvent`). |
| `output` | Typed records and effects and their JSON. |
| `models` / `host` | Shared typed models (locale, anchor, event, host metadata). |
| `json`, `reader`, `text`, `dart_time`, `name_table`, `ordered_map` | JSON, strict field readers, SHA-256 and UTF-16 helpers, Dart `DateTime`, closed vocabularies as tables, an insertion-ordered map. |

## C ABI

| Function | Purpose |
| --- | --- |
| `tb_session_engine_version()` | Library semantic version (`"0.2.0"`). |
| `tb_session_engine_abi_version()` | `TB_SESSION_ENGINE_ABI_VERSION` of the linked library (`1`). |
| `tb_session_engine_session_schema_version()` / `..._fingerprint_schema_version()` | Contract versions the engine produces (`10` / `6`). |
| `tb_session_status_name(status)` | Stable lowercase name (`"invalid_message"`), static string. |
| `tb_session_engine_create_v1(config, &engine)` | Allocates a handle. `config->abi_version` must equal the header's ABI version. Zero limits use defaults. |
| `tb_session_engine_destroy(engine)` | Frees the handle and every buffer it owns. `NULL` is a no-op. |
| `tb_session_engine_submit_v1(engine, msg, len, &out, &out_len)` | The single message entry point: one UTF-8 JSON message in, one UTF-8 JSON response out. |

Functions and structs whose layout may change carry a `_v1` suffix. A
breaking change adds `_v2` beside them and bumps
`TB_SESSION_ENGINE_ABI_VERSION`. Changing the ABI is a contract change (see
`AGENTS.md`).

### Buffer ownership

- **Message:** owned by the caller. The engine reads it only during the call
  and never keeps the pointer. A NUL terminator is not needed.
- **Response:** owned by the engine. `*out` is NUL-terminated and stays valid
  until the next `submit` or `destroy` on the same handle. The host copies
  it (for example into a `String`) and never frees it. The engine does not
  allocate per response for the host, and the host never frees anything
  except the handle.
- **Handle:** allocated by `create`, freed by `destroy`.

The engine owns the response so that a stateful engine never has to run a
message twice to size a caller buffer.

### Status codes

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `ok` | `*out` is the response. |
| 1 | `invalid_argument` | `NULL` engine or output pointer, `NULL` message with a non-zero length, or a config limit out of range. |
| 2 | `abi_mismatch` | `config->abi_version` differs from the library. |
| 3 | `malformed_message` | Not UTF-8 JSON, duplicate object key, or nested deeper than `max_depth`. |
| 4 | `invalid_message` | Valid JSON that breaks the message schema (unknown key, wrong type, missing required field, out-of-range value, or a value Dart could not encode: a non-finite number reaching the output or, on state-changing messages, anywhere in the input), or a message the engine state does not admit (an event after `session_end`, `session.start` before a host is configured, `engine.configure` during a session, any command after `engine.dispose`). A rejected message changes no state, and the host keeps owning any frame handle it carried. |
| 5 | `unsupported_message` | Unknown message `type`. |
| 6 | `contract_mismatch` | The message pins other contract versions than the engine. |
| 7 | `message_too_large` | Longer than `max_message_bytes`. |
| 8 | `busy` | A call on the same handle is already running (best-effort detection of a host bug). |
| 9 | `out_of_memory` | Allocation failed. |
| 10 | `internal_error` | Unexpected failure. Never expected. Report it. |

Whenever `engine`, `out`, and `out_len` are valid, `*out` is a JSON object:
the response on `ok`, otherwise an error document:

```json
{"error":{"status":"invalid_message","message":"unknown key","path":"$.input.host.app.label"}}
```

`malformed_message` adds the byte `offset`. Exceptions never cross the ABI.
Every entry point catches `std::bad_alloc` and anything else, and nothing
aborts on bad input. Internally the engine reports errors as return values,
not exceptions. When the build disables exceptions, the `try`/`catch` is
compiled out.

### Threading

The engine is single-threaded. The host serializes every call on a handle
through one queue, and one handle is never used concurrently. Different
handles share no state and may live on different threads. The response
buffer belongs to the handle, so the host copies it before the next call on
that queue.

### Limits

| Config field | Default | Maximum |
| --- | --- | --- |
| `max_message_bytes` | 1 MiB | 64 MiB |
| `max_depth` | 64 | 512 |

## Messages

Messages are JSON in this slice. A compact binary encoding may replace JSON
later behind the same versioning scheme: a new `_v2` entry point or a new
ABI version, never a silent change to `submit_v1`.

There are three kinds of message, all dispatched through one registry keyed
by `type`:

- **Stateless** operations (slice 2) compute a `result` from their input
  alone and never touch engine state.
- **Queries** (`session.snapshot`) read engine state and respond with a
  `result`.
- **Commands** change engine state and respond with `records` and
  `effects`. Facts among them carry the time they describe in `at`.

### Envelope

```json
{"type": "event.record", "contract": {"sessionSchemaVersion": 10, "fingerprintSchemaVersion": 6}, "at": {"monoUs": 81234567, "wallUs": 1791712345678901}, "input": { }}
```

| Key | Required | Meaning |
| --- | --- | --- |
| `type` | yes | Message type (below). |
| `input` | yes | Type-specific object (`{}` when the type takes none). |
| `at` | per type | When the fact happened (below). Optional on `engine.configure` and `session.snapshot` (validated, not used); not allowed on stateless operations. |
| `contract` | no | When present, both versions must equal the engine's, else `contract_mismatch`. An adapter that computes identity parts itself should send it. |

Unknown envelope keys are `invalid_message`.

`at` (docs/stateful-engine.md section 5):

| Field | Meaning |
| --- | --- |
| `monoUs` | Host monotonic clock in microseconds at the moment of the fact (not of submission). A non-negative integer. Required on every fact. |
| `wallUs` | UTC epoch microseconds at the same moment, within Dart's `DateTime` range. Required on `session.start`, `session.end`, `identity.set`, `traits.set`, and `transport.result`; optional elsewhere. |

The engine never reads a clock. Event `atMs` is
`floor((fact monoUs - session.start monoUs) / 1000)`, which is Dart's
`Stopwatch.elapsedMilliseconds`; a fact stamped before its session started
records `0` (change C13).

No state-changing message may carry a non-finite number anywhere in its
`input` (`1e400` parses to infinity, which Dart's `jsonEncode` cannot
write): it is `invalid_message` at that number's path.

### Batch

```json
{"type": "batch", "messages": [{"type": "session.start", "at": {…}, "input": {…}}, {"type": "event.record", "at": {…}, "input": {…}}]}
```

A batch applies commands in order in one ABI call and returns their records
and effects concatenated in order. Adapters behind an asynchronous seam send
one batch per UI frame. Rules:

- Every element is decoded and admitted against the state the earlier
  elements leave before any of them is applied. A malformed or invalid
  element rejects the whole batch with its path
  (`$.messages[2].input.stream`), and nothing applies.
- A fact that arrives after `session.end` in the same batch is not invalid:
  it is dropped like any late fact (below), and the rest of the batch
  applies.
- Only state-changing messages can be batched; batches do not nest.

### Response

```json
{"type": "fingerprint.labelHash", "result": {"hash": "…"}, "effects": []}
{"type": "event.record", "records": [{"kind": "event", "event": { }, "userId": null}], "effects": []}
```

Stateless messages and queries respond with `result` and an empty
`effects`; `result` has exactly the shape of a fixture's `expected`.
Commands and batches respond with `records` and `effects`. Hosts execute
effects in order.

The response is compact JSON. Object keys follow the Dart map insertion
order, so a record serializes byte for byte like Dart `jsonEncode` of the
same record. Fixtures do not pin byte order yet, so treat this as a goal and
not a contract.

Records are what happened, in append order (not id or `atMs` order):

| Record | Fields |
| --- | --- |
| `{"kind": "event"}` | `event`: the recorded event exactly as `TugboatEvent.toJson()`, already enriched. `userId`: the runtime user id when the event was recorded, or `null`. |
| `{"kind": "frame"}` | `handle`: the host's handle for the frame bytes. `frame`: `TugboatFrame.toJson()`. |
| `{"kind": "health"}` | `component`, and `counters`: an object of counter name to count. |

Effects are what the host must do, in order.

| Effect | Fields | Host answer |
| --- | --- | --- |
| `timer.schedule` | `timerId`, `atMonoUs` | `timer.fired {timerId}` at that host monotonic time. An armed timer with the same id is replaced. |
| `timer.cancel` | `timerId` | none |
| `http.send` | `requestId` (a string, `http-N`), `lane` (`lifecycle`, `events`, `frames`), `path`, `timeoutMs`, and either `jsonBody` or `multipart`. `jsonBody` is the request body, already encoded: the exact UTF-8 text to send (byte-identical to Dart's `jsonEncode`); hosts never re-encode it. `multipart` is `{fields, frames}`: `fields` an ordered array of `[name, value]` string pairs, `frames` an array of `{handle, filename}` file parts (form field `files`) whose bytes the host resolves from the handle. Headers (API key, app identity, content type) are the host's. | `transport.result {requestId, …}` echoing `requestId` |
| `frame.release` | `handle` | none; the host may drop the bytes |
| `capture.request` | `requestId`, `trigger`, `force`, `requireFreshPaint`, `dropWhenBusy`, `notBeforeMonoUs`, `context` (`routeEpoch`, `navigatorId?`, `routeInstanceId?`, `boundaryGeneration`), `dHashBaseline?`, `scale` | `capture.result {requestId, …}` |

### Vocabulary: stateless operations

The fixture kinds are the message types, and a fixture's `input` is the
message `input`. The field-level vocabulary is in
[conformance/README.md](../../conformance/README.md).

| `type` | Dart reference | `result` |
| --- | --- | --- |
| `fingerprint.identityParts` | `_fingerprintForParts` | `canonicalString`, `fingerprint` |
| `fingerprint.labelHash` | `tugboatLabelHash` | `hash` |
| `collector.event` | `mapTugboatEventToCollectorEvent` | `record` (one `/v1/events/batch` element) |
| `collector.sessionLifecycle` | `mapTugboatSessionLifecycleToCollectorSession` | `record` (`/v1/sessions` body) |

### Vocabulary: stateful messages

| `type` | `at` | `input` | Does |
| --- | --- | --- | --- |
| `engine.dispose` | optional | `{}` | The host's last message before `tb_session_engine_destroy`, between sessions (a live session is `invalid_message`: end it first). Reports the delivery work the collector never confirmed (below) and releases every frame delivery still references; the engine then admits no further command. |
| `engine.configure` | optional | `{host?, limits?, gesture?, interaction?, navigation?, capture?, collector?, capabilities?}` | Replaces the configuration (below). Only before the first session or between sessions. |
| `session.start` | mono + wall | `{viewport: {width, height}, platform, sessionEpoch, locale?, activationRequestId?, explorationRunId?}` | Ends a live session first (C10), resets per-session state, and records `session_start`. The session id is `session-<wallUs>` and `startedAt` is the same instant. Needs a configured `host`. |
| `session.end` | mono + wall | `{reason?}` (`session_end` or `dispose`) | Tears down in-flight work and records `session_end`. Idempotent. |
| `app.lifecycle` | mono | `{state}`: `paused`, `hidden`, `inactive`, `resumed`, `detached` | `paused`/`hidden`/`detached` tear down in-flight work. Records `app_backgrounded`, `app_foregrounded`, `app_inactive`, or `app_detached` with `data.state`, dropping consecutive duplicates by state or event type. `detached` then ends the session. |
| `event.record` | mono | `{eventType, stream, attachActionContext, data?, targetAnchor?, atMonoUs?}` | Records a toolkit-produced event (`scene_inventory`, `network_call`, `external_event`, …). `atMonoUs` (default `at.monoUs`) is the fact time. `stream` is `semantic`, `evidence`, or `diagnostic` (session schema 10). Types the engine records itself are rejected. |
| `locale.set` | mono | `{locale}` | Dedupes against the current locale, updates it, and records `locale_changed` (evidence stream, `data.previousLocale?`, `data.locale`) while a session is live. |
| `identity.set` | mono + wall | `{userId}` (string or null) | Sets the runtime user id stamped on later records. A change is posted to the collector after the identity debounce. |
| `traits.set` | mono + wall | `{traits}` (object) | Replaces the host's traits bag (it survives sessions). A bag equal to the current one (Dart `mapEquals`: shallow, nested containers never equal) is no change; a change is posted after the identity debounce. |
| `transport.result` | mono + wall | `{requestId, outcome, status?, body?}` | The host's answer to `http.send`. `outcome`: `http` (with `status` in [100, 599] and an optional `body`, the response's first 64 KiB as a string), `error`, or `timeout`. Unknown and already answered ids are ignored. |
| `transport.flush` | mono | `{}` | A flush trigger from the host, for example before the process exits. |
| `timer.fired` | mono | `{timerId}` | Routes by timer-id prefix to the module that armed the timer. Unknown, cancelled, and stale (fired before the current deadline) ids are ignored. |
| `session.snapshot` | optional | `{}` | Query. `result.snapshot` is the live or last session as `TugboatSession.toJson()` (schema 10), or `null` before the first session. |
| `input.pointer` | mono | `{pointerId, phase, x, y, device, tap?}` | A pointer fact (section 9.1). `phase`: `down`, `move`, `up`, `cancel`; `device`: `touch`, `mouse`, `stylus`, `trackpad` (validated; it does not change classification, as in Dart). `x`, `y` are logical pixels in the adapter's surface space. `tap {anchor?, failureReason?, inventory?}` is allowed on `down` (exploration pre-tap evidence) and `up`. A `pointerId` must be unique per contact. |
| `input.panZoom` | mono | `{pointerId, phase, x, y, panX?, panY?, scale?}` | A trackpad pan/zoom contact at `x, y`. `phase`: `start`, `update`, `end`. The cumulative `panX`, `panY`, and `scale` are required on `update` and not allowed otherwise. |
| `scroll` | mono | `{scrollableId, phase, offset?, axis?, maxScrollExtent?, anchor?}` | `phase`: `start`, `update`, `end`, `overscroll`. `offset` and `axis` (`vertical`, `horizontal`) are required except on `overscroll`, which carries only the id; `maxScrollExtent` gives samples their `offsetNorm`; `anchor` (the scrollable's) is allowed on `start` only. `scrollableId` is stable for the scrollable's lifetime. |
| `focus` | mono | `{kind}` | `text_input`, `other`, or `none`: what now holds primary focus. Tracked without a session too; records `focus_changed` (with `focusChanges`) only for transitions involving a text input. |
| `systemInput` | mono | `{input}` | `back`, `volume_up`, `volume_down`, `volume_mute`, `power`, `media_play_pause`. Records `system_input` with the `systemInput` capability. |
| `capture.result` | mono | `{requestId, outcome, frame?, boundaryRect?}` | The answer to a `capture.request`. `outcome`: `captured` (with `frame {handle, width, height, contentHash, masked, byteLength, captureMicros, requestedBackend?, resolvedBackend?, fallbackReason?}` and optional `boundaryRect {x, y, width, height}`), `paintUnchanged`, `failed`, `cancelled`. `requestedBackend` and `resolvedBackend` are the closed collector vocabulary (`flutterRepaintBoundary`, `nativeCpuExperimental`). This is the one way frames enter the engine. A captured frame for an unknown or invalidated request, or with no live session, is released at once (`frame.release`). |

Enrichment follows Dart `_addEvent`: the current locale is stamped when the
event has none; with `attachActionContext` the session's capture,
activation, and exploration ids are stamped, and without it only where the
event has none. Events are appended to the session, emitted as records, then
trimmed: beyond `limits.maxEvents` the oldest are dropped and the session's
`truncated` becomes and stays `true`. One counter mints `event-N`,
`frame-N`, and `capture_request-N` per engine handle; it is never reset per
session (C7, kept). The exploration action window (`actionId` stamping) is
not part of the engine; `actionId` passes through.

Event-producing facts (`event.record`, `app.lifecycle`, and the interaction
facts except `focus` and `capture.result`) without a live session, before
the first session or after `session_end` (change C9), are accepted and
dropped: no record, no id. `capture.result` without a live session releases
its frame instead. `locale.set` then only updates the locale the next
session starts with.

### Interactions

The interaction module (design section 9) builds one `interaction` event
per pointer gesture from the facts above, with Dart's controller rules:

- **Classification.** One pointer past `gesture.touchSlop` is a swipe. Two
  or more pointers form a cluster: a span change of `scaleSlop` zooms,
  shared travel of `panSlop` pans (two pointers) or swipes (three or more);
  the other pointers are absorbed. A cluster that never classifies is one
  tap per pointer. Trackpad contacts zoom past `trackpadScaleThreshold` and
  pan past `panSlop`; one that ends unclassified is `cancelled`.
- **Taps.** Pointer-up releases a tap into its claim window
  (`claimWindowMs`, timer `interaction.sweep`, capped at `maxReleased`) and
  starts its settle (timer `interaction.settle.<id>`): the settle delay,
  the rest of the claim window, then a standalone capture. Window timers
  fire `factGraceMs` late; window comparisons use fact time.
- **Swipe, pan, zoom** publish after their own capture; **scrolls** publish
  once both the pointer-up and the scroll end (and its capture, after
  `scrollEndCaptureDelayMs`, timer `interaction.scrollEnd.<id>`) have
  arrived, in either order. A scroll no pointer owned records only scroll
  samples. A tap that owns a scroll start completes as that scroll (change
  C12).
- **Captures.** Each completion emits `capture.request` (trigger
  `interaction`, forced, fresh paint; focus and system input use `manual`
  after the settle delay) and waits for `capture.result`. A `captured` frame
  is accepted as `frame-N` with a frame record. The after-frame is temporal:
  same session, completed no earlier than release, newer than the frame
  sequence at release; otherwise the latest frame when it qualifies.
- **Positions.** The latest frame at pointer-down is the before-frame;
  positions are normalised against its `boundaryRect`. Without one, or
  outside it, the interaction has no positions. `cancelled` has no payload.
- **Teardown.** `paused`, `hidden`, `detached`, `session.end`, and a
  replacing `session.start` cancel settles and outstanding captures,
  abandon pending pointers (a tap becomes `cancelled`; swipe, scroll, pan,
  and zoom keep their gesture), cancel released taps, publish waiting
  gestures and scrolls without a frame, and flush waiting `focus_changed` /
  `system_input` events, in that order. Every teardown also forgets the
  pointer contacts (change C14). Pointer input is ignored in the
  background.

Phase 3d (navigation and the capture scheduler) calls the claim API in
`interaction_claims.h` and replaces the implementation behind
`capture_seam.h`.

**Frame-accepted hook.** Whoever accepts a frame into the session emits its
frame record and then runs `ModuleRegistry::run_frame_accepted`. A module
registers with `on_frame_accepted(hook)`:

```cpp
using FrameAcceptedHook = void (*)(const Frame& frame, const std::string& handle,
                                   EngineState* state, Output* out);
```

`handle` names the frame's bytes in the host. Collector delivery (phase 3b)
uses the hook to queue the frame lane and to hold the handle's reference.

**Phase 3c limits.**

- Before-frames and frame compatibility ignore the route epoch: the
  before-frame is the session's latest frame, and a tap's capture matches
  its origin whenever the frame is known. Phase 3d adds route epochs,
  boundary generations, and the surface-compatible fallback.
- No capture scheduler: every request is issued at once, with no
  `capture_execution-N` ids, budget, suppression, reuse, perceptual-hash
  coalescing, or dedupe (phase 3d). Ids therefore differ from Dart's until
  then.
- **Blocker before any host links the engine:** a frame trimmed from the
  session (beyond `limits.maxFrames`) emits no `frame.release`, so its host
  bytes would never be released. Phase 3b is completing the handle refcount
  (design section 7.6) through the frame-accepted hook.

`engine.configure` groups, with Dart's defaults. Every field is optional and
validated. `host.configuredUserId` is the runtime user id until
`identity.set`.

| Group | Fields |
| --- | --- |
| `host` | The slice 1 `host` vocabulary. Everything the collector needs for `session_start` is required: `app.version`, `app.buildNumber`, the device with `screenSize`, `screenDensity`, `screenDpi`, and `screenPixelDensity`, `ip.ip`, and `locale` (may be `{}`). |
| `limits` | `maxEvents` 5000, `maxFrames` 500, `maxScrollSamples` 200 |
| `gesture` | `touchSlop` 18, `panSlop` 36, `scaleSlop` 18, `trackpadScaleThreshold` 1.08 |
| `interaction` | `claimWindowMs` 1250, `settleDelayMs` 1000, `maxReleased` 8, `scrollEndCaptureDelayMs` 0, `captureScrollSamples` false, `scrollCaptureIntervalMs` 2000, `factGraceMs` 0 |
| `navigation` | `routeBarrierTimeoutMs` 5000, `routeStackLimit` 16 |
| `capture` | `budgetMs` 60, `budgetWindowMs` 5000, `degradedScale` 0.8 |
| `collector` | `enabled` false, `batchSize` 10, `flushIntervalMs` 3000, `maxPendingBatches` 20, `maxPendingEvents` 60, `maxPendingFrames` 20, `frameChunk` 20, `frameTimeoutMs` 15000, `jsonTimeoutMs` 15000, `identityDebounceMs` 3000, `backgroundFlushDelayMs` 500, `endDrainTimeoutMs` 5000, `reportEventLaneGaps` false, `answerGraceMs` 5000 |
| `capabilities` | `sceneInventory`, `viewportSemanticMap`, `captureDiagnostics`, `actionContext`, `focusChanges`, `systemInput`, all false |

Durations are milliseconds in [0, 86400000]; counts are in [1, 1000000].

### Collector delivery

With `collector.enabled`, delivery (design section 7) replaces
`CollectorHttpSink`'s policy. The engine decides what to send and when; the
host performs each `http.send` and answers with `transport.result`. One
request is in flight at a time across the three lanes.

- **Lifecycle lane.** `/v1/sessions` posts in a strict FIFO: `session_start`
  (with the local session id), `session_identify`, `traits_updated`,
  `user_changed`, `session_end`. Bodies are built when sent from the current
  user id and traits; `triggeredAt` is fixed when queued and `atMs` is the
  monotonic difference (C1). The head leaves the lane only when accepted.
  An accepted `session_start` sets the collector session id from the body's
  `sessionId`, or the local id when the body is empty, not a JSON object, or
  has no non-empty string `sessionId`; any accepted body caches a non-empty
  `traitsId`.
- **Identity.** User id and traits changes wait `identityDebounceMs` after
  the last change (`delivery.identity`) and merge into one post
  (`session_identify` when both changed). While `session_start` is still
  queued they fold into its body instead.
- **Stamping.** An event's `userId` is stamped when it is recorded;
  `sessionId` and `traitsId` when its batch is sent.
- **Flush pass** (`flush_pass.cpp`): the lifecycle head; then, once a
  collector session id exists, pending frames sorted by `frameNo` in chunks
  of `frameChunk`; the retry-batch head until a retry outcome; fresh events
  in batches of `batchSize` until none is pending. Triggers: the
  `batchSize`-th pending event, the periodic `delivery.flush` timer, an
  accepted frame (unless frames need retry), `delivery.background`
  (`backgroundFlushDelayMs` after `paused`/`hidden`; `resumed` cancels it),
  `session.end`, and `transport.flush`. A trigger during a pass runs another
  pass after it (C2).
- **Outcomes.** HTTP 202 is accepted; 408, 429, 5xx, `error`, and `timeout`
  are retried; any other status drops the batch for good (C8 kept). JSON
  posts carry `jsonTimeoutMs` (C3), frame uploads `frameTimeoutMs`. Each
  request also arms `delivery.answer.<requestId>` at `timeoutMs +
  answerGraceMs`: without an answer by then it is a timeout and a late
  answer is ignored (C15). Retries are paced by triggers only.
- **Bounds** (`delivery_bounds.h`): `maxPendingEvents`, `maxPendingBatches`,
  and `maxPendingFrames` evict the oldest; failed frames are requeued at the
  front, so they go first.
- **Frames.** Every frame `capture.result` accepts is queued (a frame
  acceptance observer). A chunk with a retry outcome requeues itself and
  every later chunk; a chunk of several frames rejected with 400 is re-sent
  frame by frame, and a single frame with a retry outcome requeues from its
  own index; any other drop discards the chunk.
- **Handles.** The session and delivery each reference an accepted frame;
  `frame.release` is emitted exactly once, when the frame is trimmed from
  the session (`limits.maxFrames`) or the session ended, and delivery is
  done with it (accepted, dropped, evicted, or its upload resolved after a
  reset).
- **Gaps** (C6). Frame-lane `capture_diagnostic` events with
  `component: collector_frame_upload` (`failed`, latched until `recovered`;
  `dropped` at a cumulative 1 or power of two) are ordinary event records.
  With `reportEventLaneGaps`, evicted and rejected events are reported as
  `collector_event_upload` `dropped` (`reason` `evicted` or `rejected`) each
  time the cumulative count crosses a power of two. A gap event is queued
  like any event, so it counts toward `batchSize` and can evict another.
- **Session end** (C5). `session.end` first queues a debounced identity
  change, then holds `session_end` until frames and events drain or
  `endDrainTimeoutMs` passes (`delivery.endDrain`). The periodic timer keeps
  retrying until every lane is empty.
- **Unconfirmed work.** `engine.dispose`, and a new `session.start` that
  resets delivery (traits and the traits id survive), report the work the
  collector never confirmed once as a `health` record
  (`component: collector_delivery`): `undeliveredLifecycle`,
  `undeliveredEvents`, `undeliveredFrames` (queued: never sent, or waiting
  for a retry) and `inFlightLifecycle`, `inFlightEvents`, `inFlightFrames`
  (the request whose answer is pending). After a reset, a request still in
  flight keeps the single slot until it resolves or its answer deadline
  passes, and its result is ignored; `engine.dispose` releases its frames at
  once.

### Dart equivalence

The engine reproduces Dart behavior, including the quirks that the PR #77
design notes list. Fixing any of them is a contract change for a later slice.
Highlights:

- **Numbers.** A literal without a fraction or exponent that fits in int64 is
  an integer. Every other number is a double, including integers beyond int64
  and `-0.0`. `-0` is the integer `0`. Doubles print like Dart
  `double.toString()`: shortest round-trip digits, decimal form for decimal
  exponents in [-6, 21), otherwise `1e+21` / `1.5e-7`, and a trailing `.0` on
  integral values. Host screen metrics are always doubles (`390.0`). Overflow
  such as `1e400` parses to infinity like Dart. It fails only if it reaches the
  output, which is where Dart's `jsonEncode` throws.
- **Strings.** Strings are kept as WTF-8, so lone surrogates from `\uD800`
  escapes survive like they do in Dart's UTF-16 strings. Output escapes them
  as `\ud800`, and hashing replaces them with U+FFFD (`utf8.encode`). There is
  no Unicode normalization. Escaping matches `jsonEncode`: `\b \f \n \r \t`,
  `\u00XX` for other controls, and `/`, DEL, and U+2028 raw.
- **Identity parts.** Keys sort by UTF-16 code unit (`String.compareTo`),
  not UTF-8 bytes. `key=value` is joined with `|` without escaping. No parts
  gives `""`.
- **Time.** `triggeredAt` is `DateTime.add` on the injected epoch
  milliseconds. It uses Dart VM wrapping int64 arithmetic for `atMs * 1000`,
  so even overflowing inputs format like Dart. Values outside Dart's
  `DateTime` range are `invalid_message`, where Dart throws a `RangeError`.
  Years outside 0..9999 use `±YYYYYY`.
- **Mapping.** Behavior follows `collector_mapper.dart` exactly: envelope
  inconsistencies, `userId: null` versus an omitted `sessionId`, the
  `session_start` locale merge, traits over traitsId, and no clamping of a
  negative lifecycle `atMs`.

Where the engine is stricter than Dart's `jsonDecode`:

- Duplicate object keys are rejected. Dart keeps the last one. A collector
  response body with duplicate keys is therefore not read: a
  `session_start` falls back to the local session id.
- Invalid UTF-8 bytes are rejected. They cannot reach a Dart `String` from a
  host anyway.

## Portability

- C++17, static library, no exceptions across the ABI.
- **Android:** builds with NDK 28.2.13676358 (libc++, `c++_static`),
  `minSdk 21`.
- **Apple:** targets iOS 15. The engine does not use `std::to_chars` or
  `std::from_chars` for floating point (unavailable before iOS 16.3 / macOS
  13.3), `<filesystem>` (tests only), or locale-dependent `strtod`/`printf`
  for doubles. Float formatting and parsing come from the vendored
  double-conversion, which is the same algorithm the Dart VM uses.
- The engine never reads a clock, the environment, or the C locale.

## Third-party code

`third_party/double-conversion/` is
[google/double-conversion](https://github.com/google/double-conversion)
v3.3.0 (commit `4f7a25d8ced8c7cf6eee6fd09d6788eaa23c9afe`), BSD-3-Clause
(`LICENSE`, `AUTHORS`). The Dart VM uses it for `double.toString()` and
`double.parse`. The only change renames `namespace double_conversion` to
`namespace tb_double_conversion`, so a host app that also links
double-conversion (React Native ships it) gets no duplicate symbols. The
umbrella header `double-conversion.h` and build files are not vendored. See
[third-party-notices.md](../../docs/releases/third-party-notices.md).

## Build and test

```sh
bash tool/ci/run-session-engine-tests.sh
```

This configures with GCC, ASan, and UBSan, then runs four CTest tests.
`tb_session_engine_test`, `tb_session_engine_stateful_test`, and
`tb_session_engine_interaction_test` hold the unit
tests. `tb_session_engine_conformance` runs every `conformance/**/*.json`
through `tb_session_engine_submit_v1`. To run a subset:

```sh
./build/session-engine/tb_session_engine_conformance conformance engine/scenario
```

The conformance runner:

1. finds every `*.json` under `conformance/` recursively;
2. checks the envelope: `fixtureFormat` 1, known keys, `name` equal to the
   file stem, the directory matching `kind`, and `contract` equal to the
   versions the linked engine reports;
3. submits `{"type": kind, "contract": contract, "input": input}` with
   `input` copied byte for byte from the fixture;
4. compares `result` with `expected` using type-strict deep equality
   (`390` ≠ `390.0`, absent ≠ `null`, key order ignored). On a mismatch it
   prints one line per differing JSON path and the actual result.

`engine.scenario` fixtures run on a fresh handle: the runner sends
`input.configure` as `engine.configure`, then each step's `send` byte for
byte, and compares the step's `records` and `effects` (or its `error` status
and path) with the response. It stops a scenario at the first failing step
and names the step, its message type, every differing path, and the actual
response. Finally it compares `session.snapshot` with `finalSnapshot`. It
runs `engineOnly` scenarios too, skips fixtures whose `runners` exclude
`cpp`, and validates `engineOnly` ids against `conformance/change_ids.json`.

It parses JSON with its own small reader, so a parser bug in the engine
cannot hide itself on both sides of the comparison. It also fails when a
fixture kind has no fixtures.

Fuzzer (Clang):

```sh
cmake -S core/session-engine -B build/session-engine-fuzz \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DTB_SESSION_ENGINE_FUZZ=ON
cmake --build build/session-engine-fuzz
mkdir -p build/session-engine-fuzz/corpus
./build/session-engine-fuzz/tb_message_fuzz build/session-engine-fuzz/corpus \
  conformance -max_total_time=20 -max_len=8192
```

Android cross-compile check:

```sh
cmake -S core/session-engine -B build/session-engine-android-arm64 \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-21 \
  -DANDROID_STL=c++_static -DTB_SESSION_ENGINE_BUILD_TESTS=OFF
cmake --build build/session-engine-android-arm64
```
