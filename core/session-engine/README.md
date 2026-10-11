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
| `module_registry` | What modules contribute: message types (with their `at` rule and session policy), teardown work per stage, timers by id prefix, lifecycle hooks, and the event types the engine records itself. |
| `modules` | Registers every `*_module.cpp` once (`register_*_module`). |
| `engine_module.cpp` | `engine.configure`, `session.snapshot`, `timer.fired`. |
| `session_module.cpp` | `session.start`, `session.end`, `app.lifecycle`. |
| `evidence_module.cpp` | `event.record`, `locale.set`, `identity.set`. |
| `stateless_module.cpp` | The stateless operations (`fingerprint.cpp`, `collector.cpp`). |
| `delivery_module.cpp`, `interaction_module.cpp`, `navigation_module.cpp` | Collector delivery, interactions, and navigation and capture (design sections 7–9), each with its state header. |
| `engine_state.h` | Everything a handle holds between messages, as plain data. |
| `config` | The typed `engine.configure` configuration. |
| `lifecycle` | The lifecycle state machine, app-lifecycle mapping and dedupe, admission. |
| `clock` | `at`, `atMs` derivation, and host timer deadlines. |
| `teardown` | The ordered teardown stages. |
| `session` | The in-memory session, the id counter, and the schema 10 snapshot. |
| `recorder` | Enrichment and append (Dart `_addEvent`). |
| `output` | Typed records and effects and their JSON. |
| `models` / `host` | Shared typed models (locale, anchor, event, host metadata). |
| `json`, `reader`, `text`, `dart_time` | JSON, strict field readers, SHA-256 and UTF-16 helpers, Dart `DateTime`. |

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
| 4 | `invalid_message` | Valid JSON that breaks the message schema (unknown key, wrong type, missing required field, out-of-range value, or a value Dart could not encode: a non-finite number reaching the output or, on state-changing messages, anywhere in the input), or a message the engine state does not admit (an event after `session_end`, `session.start` before a host is configured, `engine.configure` during a session). A rejected message changes no state. |
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
| `wallUs` | UTC epoch microseconds at the same moment, within Dart's `DateTime` range. Required on `session.start`, `session.end`, and `identity.set`; optional elsewhere. |

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
| `http.send` | `requestId`, `lane` (`lifecycle`, `events`, `frames`), `path`, `timeoutMs`, and either `json` (the body) or `multipart` (`fields`: object of strings; `frames`: `[{handle, filename}]`, whose bytes the host resolves from the handle) | `transport.result {requestId, …}` |
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
| `engine.configure` | optional | `{host?, limits?, gesture?, interaction?, navigation?, capture?, collector?, capabilities?}` | Replaces the configuration (below). Only before the first session or between sessions. |
| `session.start` | mono + wall | `{viewport: {width, height}, platform, sessionEpoch, locale?, activationRequestId?, explorationRunId?}` | Ends a live session first (C10), resets per-session state, and records `session_start`. The session id is `session-<wallUs>` and `startedAt` is the same instant. Needs a configured `host`. |
| `session.end` | mono + wall | `{reason?}` (`session_end` or `dispose`) | Tears down in-flight work and records `session_end`. Idempotent. |
| `app.lifecycle` | mono | `{state}`: `paused`, `hidden`, `inactive`, `resumed`, `detached` | `paused`/`hidden`/`detached` tear down in-flight work. Records `app_backgrounded`, `app_foregrounded`, `app_inactive`, or `app_detached` with `data.state`, dropping consecutive duplicates by state or event type. `detached` then ends the session. |
| `event.record` | mono | `{eventType, stream, attachActionContext, data?, targetAnchor?, atMonoUs?}` | Records a toolkit-produced event (`scene_inventory`, `network_call`, `external_event`, …). `atMonoUs` (default `at.monoUs`) is the fact time. `stream` is `semantic`, `evidence`, or `diagnostic` (session schema 10). Types the engine records itself are rejected. |
| `locale.set` | mono | `{locale}` | Dedupes against the current locale, updates it, and records `locale_changed` (evidence stream, `data.previousLocale?`, `data.locale`) while a session is live. |
| `identity.set` | mono + wall | `{userId}` (string or null) | Sets the runtime user id stamped on later records. |
| `timer.fired` | mono | `{timerId}` | Routes by timer-id prefix to the module that armed the timer. Unknown, cancelled, and stale (fired before the current deadline) ids are ignored. |
| `session.snapshot` | optional | `{}` | Query. `result.snapshot` is the live or last session as `TugboatSession.toJson()` (schema 10), or `null` before the first session. |

Enrichment follows Dart `_addEvent`: the current locale is stamped when the
event has none; with `attachActionContext` the session's capture,
activation, and exploration ids are stamped, and without it only where the
event has none. Events are appended to the session, emitted as records, then
trimmed: beyond `limits.maxEvents` the oldest are dropped and the session's
`truncated` becomes and stays `true`. One counter mints `event-N`,
`frame-N`, and `capture_request-N` per engine handle; it is never reset per
session (C7, kept). The exploration action window (`actionId` stamping) is
not part of the engine; `actionId` passes through.

Event-producing facts (`event.record`, `app.lifecycle`) without a live
session, before the first session or after `session_end` (change C9), are
accepted and dropped: no record, no id. `locale.set` then only updates the
locale the next session starts with.

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
| `collector` | `enabled` false, `batchSize` 10, `flushIntervalMs` 3000, `maxPendingBatches` 20, `maxPendingEvents` 60, `maxPendingFrames` 20, `frameChunk` 20, `frameTimeoutMs` 15000, `jsonTimeoutMs` 15000, `identityDebounceMs` 3000, `backgroundFlushDelayMs` 500, `endDrainTimeoutMs` 5000, `reportEventLaneGaps` false |
| `capabilities` | `sceneInventory`, `viewportSemanticMap`, `captureDiagnostics`, `actionContext`, `focusChanges`, `systemInput`, all false |

Durations are milliseconds in [0, 86400000]; counts are in [1, 1000000].

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

- Duplicate object keys are rejected. Dart keeps the last one.
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

This configures with GCC, ASan, and UBSan, then runs three CTest tests.
`tb_session_engine_test` and `tb_session_engine_stateful_test` hold the unit
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
