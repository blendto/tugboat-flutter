# C++ session engine

The I/O-free, single-threaded session engine from
[ADR 0009](../../docs/decisions/0009-shared-session-engine.md). Its public
surface is a versioned C ABI (`include/tugboat/tb_session_engine.h`). A
platform host (Kotlin, Swift) owns one engine handle, submits facts as
messages, and executes the records and effect requests the engine returns.

Status: skeleton (ADR 0009 slice 2). It implements only the stateless
operations that the [conformance fixtures](../../conformance/README.md) pin,
which are fingerprint hashing and collector record mapping. It reproduces the
current Dart implementation exactly. No runtime or adapter links it yet. Like
`core/image-processing`, it is never copied into a pub package. It will ship
inside the platform runtimes (ADR 0003).

## Layout

```text
core/session-engine/
  include/tugboat/tb_session_engine.h   public C ABI (no C++ types)
  src/                                  engine (C++17, internal headers)
  tests/tb_session_engine_test.cpp      unit tests (internals + ABI error paths)
  tests/tb_session_engine_conformance.cpp  fixture runner (public ABI only)
  fuzz/message_fuzz.cpp                 libFuzzer target for submit
  third_party/double-conversion/        vendored, see "Third-party code"
```

## C ABI

| Function | Purpose |
| --- | --- |
| `tb_session_engine_version()` | Library semantic version (`"0.1.0"`). |
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
| 4 | `invalid_message` | Valid JSON that breaks the message schema: unknown key, wrong type, missing required field, out-of-range value, or a value Dart could not encode (non-finite number reaching the output). |
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

### Envelope

```json
{"type": "collector.event", "contract": {"sessionSchemaVersion": 10, "fingerprintSchemaVersion": 6}, "input": { }}
```

| Key | Required | Meaning |
| --- | --- | --- |
| `type` | yes | Message type (below). |
| `input` | yes | Type-specific object. |
| `contract` | no | When present, both versions must equal the engine's, else `contract_mismatch`. An adapter that computes identity parts itself should send it. |

Unknown envelope keys are `invalid_message`.

### Response

```json
{"type": "collector.event", "result": {"record": { }}, "effects": []}
```

`result` has exactly the shape of a fixture's `expected`. `effects` is always
empty in this slice. Hosts should already loop over it.

The response is compact JSON. Object keys follow the Dart map insertion
order, so a record serializes byte for byte like Dart `jsonEncode` of the
same record. Fixtures do not pin byte order yet, so treat this as a goal and
not a contract.

### Vocabulary (implemented)

The fixture kinds are the message types, and a fixture's `input` is the
message `input`. The field-level vocabulary is in
[conformance/README.md](../../conformance/README.md).

| `type` | Dart reference | `result` |
| --- | --- | --- |
| `fingerprint.identityParts` | `_fingerprintForParts` | `canonicalString`, `fingerprint` |
| `fingerprint.labelHash` | `tugboatLabelHash` | `hash` |
| `collector.event` | `mapTugboatEventToCollectorEvent` | `record` (one `/v1/events/batch` element) |
| `collector.sessionLifecycle` | `mapTugboatSessionLifecycleToCollectorSession` | `record` (`/v1/sessions` body) |

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

## Planned messages (not implemented)

The stateful engine will take over `TugboatReplayController` orchestration.
The expected vocabulary, which changes with the next slices:

- **Session:** `session.start` (host metadata, injected clock, ids),
  `session.end`, `session.identify` / `traits`. The engine holds session
  state, user and traits ids, and event sequencing.
- **Adapter facts:** pointer down/move/up/cancel, scroll start/update/end,
  navigation (push/pop/replace, overlays), focus and text input, anchors and
  identity parts, and frame-capture results. The engine forms interaction
  transactions and dedup decisions from these facts.
- **Host signals:** `clock.tick` and timer fires, `delivery.ack` /
  `delivery.failed` for a batch id, and lifecycle (background, foreground,
  terminate).
- **Effects** (in `effects`): `collector.sendBatch` (records plus a batch id),
  `collector.sendSession`, `timer.schedule` / `timer.cancel` (flush), and
  `frame.capture` requests. The host executes them and reports the result
  back as messages, so the engine never performs I/O or reads a clock.
- **Records** that a stateful message emits will appear in the response
  next to `effects`.

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

This configures with GCC, ASan, and UBSan, then runs two CTest tests.
`tb_session_engine_test` holds the unit tests.
`tb_session_engine_conformance` runs every `conformance/**/*.json` through
`tb_session_engine_submit_v1`. To run a subset:

```sh
./build/session-engine/tb_session_engine_conformance conformance collector/event
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
