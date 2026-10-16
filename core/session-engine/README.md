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
  tests/tb_session_engine_delivery_test.cpp  unit tests (delivery)
  tests/tb_session_engine_capture_test.cpp  unit tests (scheduler, frame store, budget, navigator registry)
  tests/tb_session_engine_evidence_test.cpp  unit tests (Dart strings, jsonDecode parser options, bounded work)
  tests/tb_session_engine_conformance.cpp  fixture runner (public ABI only)
  tests/conformance/                    runner JSON reader, diff, scenario and evidence runners
  fuzz/message_fuzz.cpp                 libFuzzer target for submit
  docs/stateful-engine.md               accepted stateful design
  docs/evidence-messages.md             evidence messages, value encoding, host obligations
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
| `evidence_messages.cpp` | `evidence.externalEvent`, `evidence.networkCall` ([docs/evidence-messages.md](docs/evidence-messages.md)): decoding, the no-session and stale-call drops, duration, recording. |
| `evidence_value`, `evidence_parameters`, `evidence_network` | The typed value encoding, decoded once into `EvidenceValue` (`jsonText` bodies convert into the same tree); Dart's parameter policy and limits; method, route, and error-body normalization (one pass that stops at the 4 KiB cap, then a single `encode_json`). |
| `identity_module.cpp` | `identity.set`, `traits.set`: the runtime user id and the traits bag, with change detection. |
| `frame_retention`, `frame_retention_module.cpp` | Who references each accepted frame: the session (taken and trimmed by the capture seam, dropped at session end) and delivery; `frame.release` once both let go (design section 7.6). |
| `stateless_module.cpp` | The stateless operations (`fingerprint.cpp`, `collector.cpp`). |
| `collector_mapping` | The one collector wire mapping (`collector_mapper.dart`), shared by the stateless operations and delivery. |
| `delivery_module.cpp` | Collector delivery (design section 7): `transport.result`, `transport.flush`, the `delivery.` timers, hooks, and observers. Its state is `delivery_state.h`; the parts below each hold one concept. |
| `delivery`, `delivery_lanes`, `flush_pass` | Delivery phases, triggers, identity, and the session end drain; queueing events and frames, gaps, and release; the flush pass cursor and response handling (`flush_cursor.h` holds its state). |
| `lifecycle_lane`, `event_queue`, `frame_lane`, `delivery_gaps`, `delivery_bounds`, `transport` | The `/v1/sessions` FIFO, the identity debounce that feeds it, and the handshake; pending events and retry batches with send-time stamping; pending frames and the multipart body; gap thresholds; every queue bound and its eviction rule; `transport.result` and its classification. |
| `navigation_module.cpp` | Navigation (design section 8.1): the `navigation` fact, the `navigation.` timers, the route-capture teardown stage. Its state is `navigation_state.h`; the parts below each hold one concept. |
| `navigation_facts`, `navigator_registry`, `route_change` | The typed `navigation` fact; `nav-N` / `route-N` ids, stacks, presentedOver / hostPage; how a fact resolves into a visible change (invisible removal, cause claim) and the `route_change` envelope. |
| `route_work.h`, `route_capture`, `route_barrier` | The route-capture work state machine as data and its transitions (supersession, deadline, finalize, timeout, teardown); waiting on a route barrier and following `supersededBy`. |
| `navigation_view` | What other modules read from navigation: the route stamp, the request context, transition suppression (C11), the active and causal route captures. |
| `capture_module.cpp` | Capture coordination (design section 8.2): `capture.result`, `surface`, the `capture.due` timer, the capture-work teardown stage, the `initial` and `lifecycle` captures. |
| `capture_seam` | The capture seam (`EngineState::captures`): requests, the pump, the decision order, per-waiter resolution, `capture_diagnostic`. The parts below each hold one concept. |
| `capture_types`, `capture_facts` | The capture vocabulary (owners, outcomes, cancel reasons, mask coverage); the `capture.result` and `surface` decoders. |
| `capture_scheduler`, `capture_execution`, `frame_store`, `capture_budget`, `capture_diagnostics` | The FIFO with tail absorption and the one capture in flight; what an execution resolves to; frame provenance, compatibility, coalesce baselines, and trim; the rolling screenshot budget; the diagnostic events. |
| `coordination`, `coordination_module.cpp` | Deferred work (capture answers, barrier resumes) run after every command, and the serialized publication queue (design section 9.3 #3). |
| `fact_command.h`, `turn.h` | A command made of one typed fact; what every stateful step works on (state, live session, fact time, output). |
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
| `interaction_facts` | Typed interaction facts. |
| `interaction_claims` | What navigation calls: the claim API, the settle wake hook, and attaching the route frame to the cause. |
| `engine_state.h` | Everything a handle holds between messages, as plain data. |
| `config` | The typed `engine.configure` configuration. |
| `lifecycle` | The lifecycle state machine, app-lifecycle mapping and dedupe, admission. |
| `clock` | `at`, `atMs` derivation, and host timer deadlines. |
| `teardown` | The ordered teardown stages. |
| `session` | The in-memory session (events, frames, scroll samples), the id counter, and the schema 10 snapshot. |
| `recorder` | Enrichment and append (Dart `_addEvent`). |
| `output` | Typed records and effects and their JSON. |
| `models` / `host` | Shared typed models (locale, anchor, event, host metadata). |
| `json`, `reader`, `text`, `dart_time`, `name_table`, `ordered_map` | JSON (with `ParseOptions` for Dart `jsonDecode` semantics), strict field readers, SHA-256, the one WTF-8 decoder and the Dart `String` helpers (UTF-16 length and cut, `trim`, UTF-8 prefix), Dart `DateTime`, closed vocabularies as tables, an insertion-ordered map. |

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
| `capture.request` | `requestId` (`capture-N`, one per physical capture), `trigger`, `force` (capture even when the paint is unchanged), `requireFreshPaint`, `dropWhenBusy` (informative), `notBeforeMonoUs` (already reached: the engine waits itself), `context` (`routeEpoch`, `navigatorId?`, `routeInstanceId?`, `boundaryGeneration`), `dHashBaseline?` (`{dHash, structureSignature}`), `scale` | `capture.result {requestId, …}`, exactly one per request |

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
| `evidence.externalEvent` | mono | `{name, source?, policy {mode, allowedKeys?}, parameters?, atMonoUs?}` | Records an `external_event` (evidence stream, no action context) after applying Flutter's parameter policy (`names_only`, `allow_list`, `transform` with host-run results, `allow_all`), parameter limits, and name/source bounding. `parameters` uses the typed value encoding of [docs/evidence-messages.md](docs/evidence-messages.md). An empty name records nothing. |
| `evidence.networkCall` | mono | `{method, route, startMonoUs, endMonoUs?, statusCode?, outcome, attemptCount?, errorResponseBody?}` | Records a `network_call` at `startMonoUs` (C19) with `durationMs` from the two monotonic times, after Flutter's method and route normalization and, for `statusCode` ≥ 400, error-body normalization (`errorResponseBody` is `{value}` or `{jsonText}`). An invalid method or route, or a call that began before the live session, records nothing. |
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
| `capture.result` | mono | `{requestId, outcome, frame?, boundaryRect?, failure?, timings?}` | The answer to a `capture.request`. `outcome`: `captured` (with `frame {handle, width, height, contentHash, dHash?, structureSignature?, masked, byteLength, captureMicros, requestedBackend?, resolvedBackend?, fallbackReason?, maskCoverage?}` and optional `boundaryRect {x, y, width, height}`), `paintUnchanged` (only for a request without `force`), `failed` (optional `failure`: `boundaryUnavailable`, `boundaryDetached`, `boundaryReplaced`, `layoutUnavailable`, `paintTimedOut`, `paintNotAdvanced`, `readbackFailed`, `maskFailed`, `encodingFailed`, `secureWindow`), `cancelled`. `maskCoverage {mode, reasons}` (native hosts) says which mask mode applied: `mode` is `precise`, `wholeHost`, or `wholeFrame`; `reasons` is an array (may be empty) of at most 8 distinct names from `composeDefault`, `composeVersionUnverified`, `composeOwnerUnavailable`, `interop`, `regionUnreadable`, `treeUnreadable`, `animating`, `unverifiedLayerAllowlist`, `walkExhausted`, `noWindowSize`, `noDecor`, `representable`, `webView`, `renderer`, `surfaceLayer`, `unclassifiedLayer`, `secureText` (every value the Android and SwiftUI adapters emit). `timings {frameWaitMicros?, readbackMicros?, maskMicros?, encodeMicros?}` (each at most a day) feed the screenshot budget. `requestedBackend` and `resolvedBackend` are the closed collector vocabulary (`flutterRepaintBoundary`, `nativeCpuExperimental`); `dHash` and `structureSignature` are opaque tokens the engine only compares. This is the one way frames enter the engine. A captured frame the engine does not accept (an unknown, stale, or teardown-abandoned request, a reuse, a perceptual match, or no live session) is released at once (`frame.release`). |
| `navigation` | mono | `{kind, navigatorId, parentNavigatorId?, route?, departing?}` | A navigator callback (section 8.1). `kind`: `push`, `pop`, `replace`, `remove`. `route {instanceId, name?, type, overlayKind, transitionMs}` is the destination: the pushed route, the replacement, or the route a pop or removal reveals (absent when none is). `overlayKind`: `page`, `sheet`, `dialog`, `popup`, `unknown`; `transitionMs` in [0, 86400000]. `departing {instanceId, name?, type?}` is the route leaving or covered; only its id is read (`from*` fields come from the visible route, as in Dart). Ids are opaque, stable for the navigator's or route's lifetime; the engine maps them onto `nav-N` / `route-N` per session. A navigator first named as `parentNavigatorId` is numbered after its child. |
| `surface` | mono | `{boundaryRect {x, y, width, height}, generation}` | The capture boundary in surface logical pixels and the adapter's boundary transform generation, which advances whenever the boundary's rect changes. Send it after `session.start` and on every change, before the `capture.result` of a capture made under it. |

Enrichment follows Dart `_addEvent`: the current locale is stamped when the
event has none; with `attachActionContext` the session's capture,
activation, and exploration ids are stamped, and without it only where the
event has none. Events are appended to the session, emitted as records, then
trimmed: beyond `limits.maxEvents` the oldest are dropped and the session's
`truncated` becomes and stays `true`. One counter mints `event-N`,
`frame-N`, `capture_request-N`, and `capture_execution-N` per engine
handle, in Dart's order; it is never reset per session (C7, kept). The
host's `capture-N` request ids have their own counter. The exploration action window (`actionId` stamping) is
not part of the engine; `actionId` passes through.

Event-producing facts (`event.record`, `evidence.externalEvent`,
`evidence.networkCall`, `app.lifecycle`, `navigation`,
`surface`, and the interaction facts except `focus`) without a live session, before
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
- **Captures.** Each completion asks the capture scheduler (below) for a
  capture (trigger `interaction`, forced, fresh paint; focus and system
  input use `manual` after the settle delay) and waits for its answer. The
  after-frame is temporal: same session, completed no earlier than release,
  newer than the frame sequence at release. A swipe, pan, zoom, or scroll
  whose own capture gave no fresh temporal frame walks the route barriers
  (the active route capture, then the routes that superseded it), then
  takes the latest frame when it qualifies.
- **Positions.** The before-frame is the latest frame when it is compatible
  with the pointer-down's context (route epoch, route, navigator, route
  instance, boundary generation). Positions are normalised against that
  frame's `boundaryRect` (or the observed boundary). Without an observed
  boundary, a frame of the current boundary generation, or outside the
  boundary, the interaction has no positions. `cancelled` has no payload.
- **Teardown.** `paused`, `hidden`, `detached`, `session.end`, and a
  replacing `session.start` cancel settles and outstanding captures,
  abandon pending pointers (a tap becomes `cancelled`; swipe, scroll, pan,
  and zoom keep their gesture), cancel released taps, publish waiting
  gestures and scrolls without a frame, and flush waiting `focus_changed` /
  `system_input` events, in that order. Every teardown also forgets the
  pointer contacts (change C14). Pointer input is ignored in the
  background.

**Frame-accepted hook.** Whoever accepts a frame into the session emits its
frame record and then runs `ModuleRegistry::run_frame_accepted`. A module
registers with `on_frame_accepted(hook)`:

```cpp
using FrameAcceptedHook = void (*)(const Frame& frame, const std::string& handle,
                                   EngineState* state, Output* out);
```

`handle` names the frame's bytes in the host. Collector delivery (phase 3b)
uses the hook to queue the frame lane and to hold the handle's reference.

### Navigation and captures

The navigation module and the capture seam (design section 8) reproduce
the Dart controller's route observer, route-capture barriers, and capture
scheduler:

- **Navigation.** A removal revealing no route, or the visible route, is
  invisible. Otherwise the stacks update, the visual observation
  generation advances, and the cause is claimed (exactly one eligible
  transaction, same navigator) before the route epoch advances. Prior work
  on the same navigator is cancelled with every waiting capture
  (`superseded_route`) and links its successor; the capture generation
  advances. The claimed tap is woken once the barrier is registered. After
  `transitionMs + settleDelayMs` (timer `navigation.deadline.<epoch>`) the
  route joins the publication queue, requests a forced `route` capture, and
  records `route_change` (`navigated`, the frame as `afterFrame`, or
  `captureOutcome: failed` with `captureFailure`). After
  `routeBarrierTimeoutMs` more (timer `navigation.timeout.<epoch>`) it
  records `route_change` with `captureOutcome: timed_out` (`unknown`)
  instead. Superseded work records no `route_change`.
- **Taps and routes.** A tap that caused the route active at its pointer-up
  skips the settle delay; a tap claimed later stops waiting out its claim
  window. Either waits for its route's barrier (following successors it
  also caused) and takes the route frame. A tap whose route was replaced by
  one it did not cause, or whose standalone capture was overtaken by a
  later route, observes that route's frame only as a temporal observation.
- **Scheduler.** Requests (`capture_request-N`) queue FIFO; a request joins
  the tail when both are compatible and neither is an `interaction`
  capture (the higher-priority trigger wins: manual > interaction > route >
  lifecycle > tap > scroll > initial). One capture is in flight; the engine
  waits out each head's not-before time with timer `capture.due`.
  `dropWhenBusy` requests resolve `capture_pressure_drop` while busy.
- **Decision order.** Suppressed (`route_transition`, while the context's
  navigator is in a transition, change C11); budget skip (degraded budget,
  reusable capture, compatible frame); stale context (route epoch, route,
  boundary generation, or capture generation changed: never reaches the
  host); then the host's answer: paint-unchanged reuse, perceptual
  coalescing (the offered `dHashBaseline` matched under the same
  structure), exact-content reuse (a compatible retained frame with the
  same `contentHash`), or `fresh_accepted`. An answer whose context went
  stale meanwhile is `superseded_route_epoch`. Each waiter keeps the frame
  only when it is compatible with its own context.
- **Ids and diagnostics.** One `capture_execution-N` per execution (one per
  request for cancellations and rejections), in Dart's order. With
  `capabilities.captureDiagnostics` every resolution records
  `capture_diagnostic` (diagnostic stream) as Dart does.
- **Mask coverage.** An accepted frame with `maskCoverage` always records
  `capture_diagnostic` `{component: capture_masking, frameId, mode,
  reasons}` (`afterFrame` the new frame) right after its frame record,
  before anything the frame-accepted hooks record (a delivery eviction
  gap), with or without `captureDiagnostics`, so Atlas can tell a
  whole-masked frame from a broken capture. Frame records and
  `frameMetadata` never carry it; a frame without `maskCoverage`
  (Flutter, older hosts) records nothing new, and neither does a frame
  the engine coalesces, reuses, or releases (stale, unknown, no session).
- **Secure windows.** `failed` with `secureWindow` (a window flagged
  secure is never copied) resolves as `capture_processing_failed`, like
  the other non-retryable failures; its `capture_diagnostic` carries
  `failure: secure_window`. Without `captureDiagnostics` it is recorded
  only for the first secure window of each route instance in a session
  (before any route, the session counts as one), so a secure screen
  captured again and again cannot flood the event queue. Later ones are
  counted, and every teardown (going to the background, session end or
  replacement) records `capture_diagnostic` `{component:
  capture_secure_window, routeInstanceId?, repeatCount}` for each route
  instance with repeats since the last report, in first-failure order.
  With `captureDiagnostics` every one is recorded and nothing is counted.
- **Budget.** Each execution charges its queue wait (the settle delay
  included, as in Dart) and the host's `timings` within `budgetWindowMs` of
  fact time (C1). Over `budgetMs`, requests carry `scale: degradedScale`.
- **Host contract.** The host answers every `capture.request` by its id
  and must not assume one at a time: teardown stops waiting for the capture
  in flight (change C16), so a new request can arrive while the host still
  performs an abandoned one, whose late answer is ignored (frame released).
  A request unanswered `capture.answerTimeoutMs` after it was issued (timer
  `capture.answer.<requestId>`, change C18) resolves as
  `paint_readiness_timeout`; a forced request answered `paintUnchanged`
  resolves as `capture_processing_failed`. Both record `capture_diagnostic`
  with `failure` (`answer_timeout`, `contract_violation`) even without the
  `captureDiagnostics` capability, and a late answer is ignored.
- **Lifecycle.** `session.start` requests a forced `initial` capture after
  `session_start`; `resumed` requests a forced `lifecycle` capture before
  `app_foregrounded`. Teardown cancels every request and stops waiting for
  the capture in flight.
- **Deferred work.** Capture answers and barrier resumes reach their
  waiters after the command that produced them, as Dart microtasks do.
  Route finalization, settled taps with a frame, and completed gestures
  publish through one serialized queue that a route finalize holds until
  its route is done; a degraded tap observation publishes at once.
- **Trim.** Beyond `limits.maxFrames` the oldest frame leaves the session
  with a tombstone (never attached or reused again), and the session's
  reference to its handle is released (section 7.6).

Not modelled: exploration frame suppression and `pause_capture` (host
side), and Dart's paint-unchanged retry (unreachable here: the latest
frame only changes when a capture resolves, and one is in flight).

`engine.configure` groups, with Dart's defaults. Every field is optional and
validated. `host.configuredUserId` is the runtime user id until
`identity.set`.

| Group | Fields |
| --- | --- |
| `host` | The slice 1 `host` vocabulary. Everything the collector needs for `session_start` is required: `app.version`, `app.buildNumber`, the device with `screenSize`, `screenDensity`, `screenDpi`, and `screenPixelDensity`, `ip.ip`, and `locale` (may be `{}`). |
| `limits` | `maxEvents` 5000, `maxFrames` 500, `maxScrollSamples` 200 |
| `gesture` | `touchSlop` 18, `panSlop` 36, `scaleSlop` 18, `trackpadScaleThreshold` 1.08 |
| `interaction` | `claimWindowMs` 1250, `settleDelayMs` 1000, `maxReleased` 8, `scrollEndCaptureDelayMs` 0, `captureScrollSamples` false, `captureScrollScreenshots` false, `scrollCaptureIntervalMs` 2000, `factGraceMs` 0 |
| `navigation` | `routeBarrierTimeoutMs` 5000, `routeStackLimit` 16 |
| `capture` | `budgetMs` 60, `budgetWindowMs` 5000, `degradedScale` 0.8, `answerTimeoutMs` 5000 (change C18) |
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
- **Evidence.** `evidence.externalEvent` and `evidence.networkCall` data
  equals `TugboatEvidenceRecorder`'s, byte for byte (the `conformance/
  evidence/` fixtures run on both runners). Two differences are deliberate:
  a `network_call` keeps its start as `atMs` (C19; Dart stamps the finish),
  and a non-ASCII method records nothing (Dart upper-cases it with Unicode
  simple case mapping).
- **Mapping.** Behavior follows `collector_mapper.dart` exactly: envelope
  inconsistencies, `userId: null` versus an omitted `sessionId`, the
  `session_start` locale merge, traits over traitsId, and no clamping of a
  negative lifecycle `atMs`.
- **Anchor toolkit.** Native adapters may add `toolkit` to any anchor
  (`view`, `compose`, `swiftui`, `uikit`, `react-native`; anything else is
  `invalid_message`). The Dart models have no such field: the engine passes
  it through, as the last key, into event records and every collector
  `targetAnchor` (the interaction's reduced anchor too), and never hashes
  it. Without it, output is byte-identical to Dart.

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

This configures with GCC, ASan, and UBSan, then runs six CTest tests.
`tb_session_engine_test`, `tb_session_engine_stateful_test`,
`tb_session_engine_interaction_test`, `tb_session_engine_delivery_test`, and
`tb_session_engine_capture_test` hold the unit tests. `tb_session_engine_conformance` runs every `conformance/**/*.json`
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
