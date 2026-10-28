# Conformance fixtures

Language-neutral golden fixtures for the session engine described in
[ADR 0009](../docs/decisions/0009-shared-session-engine.md). Each fixture
gives the facts a toolkit adapter or platform host submits and the exact
record the engine must produce. The current Dart implementation in
`package:tugboat` must match every fixture, and so must the C++ engine when it
exists. These fixtures are what keeps the two equivalent.

This folder is outside the pub package on purpose: it is never published to
pub.dev and no runtime reads it.

Three families of fixture:

- Stateless operations: fingerprint hashing of supplied identity parts and
  collector record mapping for one event or one session lifecycle record.
- Evidence: the `external_event` / `network_call` data the engine records
  for one `evidence.externalEvent` / `evidence.networkCall` message, which
  must equal what Dart's `TugboatEvidenceRecorder` records.
- `engine.scenario`: a sequence of stateful engine messages and the records
  and effects each one produces, plus the final session snapshot
  ([stateful design](../core/session-engine/docs/stateful-engine.md)
  section 10).

## Layout

```text
conformance/
  README.md
  change_ids.json                   section 11 change ids (not a fixture)
  retry_after_vectors.json          shared Retry-After parser vectors (not a fixture)
  fingerprint/
    identity_parts/<name>.json      kind fingerprint.identityParts
    label_hash/<name>.json          kind fingerprint.labelHash
    inventory_hash/<name>.json      kind fingerprint.inventoryHash
  collector/
    event/<name>.json               kind collector.event
    session_lifecycle/<name>.json   kind collector.sessionLifecycle
  engine/
    scenario/<name>.json            kind engine.scenario
  evidence/
    external_event/<name>.json      kind evidence.externalEvent
    network_call/<name>.json        kind evidence.networkCall
  host/                             byte-exact platform host fixtures (not *.json; see host/README.md)
```

One case per file. The file name stem equals the fixture `name`, and the
directory is fixed by `kind`. A runner loads every `*.json` except
`change_ids.json` under
`conformance/` recursively.

## Fixture envelope

```json
{
  "fixtureFormat": 1,
  "kind": "collector.event",
  "name": "interaction-tap-full",
  "description": "What this case pins and why.",
  "contract": { "sessionSchemaVersion": 10, "fingerprintSchemaVersion": 6 },
  "input": { },
  "expected": { }
}
```

| Field | Meaning |
| --- | --- |
| `fixtureFormat` | Version of this envelope. Currently `1`. |
| `kind` | Operation under test; selects the `input` and `expected` shapes below. |
| `name` | Kebab-case id, equal to the file name stem. |
| `description` | Human explanation. Not an input. |
| `contract` | SDK contract versions the expected value was reviewed against. A runner must fail when its own versions differ. |
| `input` | The facts submitted to the engine. Unknown keys are an error. |
| `expected` | The engine's output for `input`. |
| `engineOnly` | `engine.scenario` only, optional. The ids of the deliberate changes in the stateful design's section 11 that the scenario encodes, from `change_ids.json` (the single list both runners read). Implies `runners: ["cpp"]`. Any other id, a duplicate, an empty list, or the key on another kind is an error. |
| `runners` | Optional, any kind. The runners that run the fixture: a non-empty list of distinct `cpp` and `dart`, default both. For fixtures the Dart runner cannot express without claiming a section 11 change, such as engine vocabulary the Flutter models do not have (an anchor's native `toolkit`). With `engineOnly`, only `["cpp"]` is allowed. |
| `dartParity` | `engine.scenario` only, optional: `"delivery"`. The Dart runner runs the scenario in delivery replay mode instead of skipping it, even when it is `engineOnly` for a change outside the collector wire: it feeds the engine's published records into the real `CollectorHttpSink` and compares only `http.send` effects. Not allowed with `runners`. |

Files are UTF-8 JSON with 2-space indent and are ASCII-only: every non-ASCII
character is written as a `\uXXXX` escape, using a UTF-16 surrogate pair above
U+FFFF. NFC and NFD text look identical when rendered, so they must be
escaped to be reviewable.

## Kinds and input vocabulary

The input vocabulary is a first draft of the engine's input messages.
Absent and `null` mean the same thing in inputs. In outputs they differ (see
[Comparison](#comparison)).

### `fingerprint.identityParts`

Hashes identity parts into a fingerprint (fingerprint schema v6). Toolkit
adapters compute the parts. The engine owns only the hash.

| Input | Type | Meaning |
| --- | --- | --- |
| `parts` | array of `[key, value]` string pairs | Identity parts in submission order. Keys are unique. Order does not affect the result. |

| Expected | Meaning |
| --- | --- |
| `canonicalString` | Parts sorted by key, comparing UTF-16 code units (Dart `String.compareTo`), written as `key=value`, joined with `\|`. Separators are not escaped. |
| `fingerprint` | First 16 lowercase hex characters of SHA-256 over the UTF-8 bytes of `canonicalString`, or `""` when `parts` is empty. |

Parts the Flutter adapter submits today:

- Target `fingerprint`: `routeKey` and `path` (the full canonical path).
- `tagFingerprint`: `routeKey` and `tag`.

`routeKey` is the route name, or `struct:<signature>` for anonymous routes.

### `fingerprint.labelHash`

The privacy hash for labels (`tugboatLabelHash`).

| Input | Type | Meaning |
| --- | --- | --- |
| `value` | string | Text to hash. |

| Expected | Meaning |
| --- | --- |
| `hash` | First 16 lowercase hex characters of SHA-256 over the UTF-8 bytes, or `""` for `""`. |

### `fingerprint.inventoryHash`

Scene inventory hash (`tugboatInventoryHash`): sorted element fingerprints joined by `|`, then `tugboatLabelHash`.

| Input | Type | Meaning |
| --- | --- | --- |
| `fingerprints` | string array | Element fingerprints in any order. |

| Expected | Meaning |
| --- | --- |
| `hash` | `tugboatLabelHash` of the sorted fingerprints joined by `\|`. |

### Shared collector inputs

`host`: what the platform host knows about the app, device, and network at
session start. It corresponds to `TugboatCollectorConfig` without transport
settings (base URL, API key, batching).

| Field | Type | Meaning |
| --- | --- | --- |
| `app.name` | string | Display name. Never sent. |
| `app.version` | string | Version name, sent as `versionName` / `appInfo.version`. |
| `app.buildNumber` | string | Build number. |
| `app.installationId` | string | Per-install id. Not sent in session records. |
| `app.appId` | string | Package or bundle id. Also sent as `packageName`. |
| `device.id` | string | Device id. |
| `device.platform` | string | `android`, `ios`, and so on. Part of build identity. |
| `device.manufacturer`, `device.model`, `device.osVersion` | string, optional | Device facts. |
| `device.batteryPercent`, `device.storageFreeMb`, `device.ramMb` | integer, optional | Device facts at session start. |
| `device.networkType` | string, optional | `wifi`, `cellular`, `ethernet`, `vpn`, `none`, `other`. |
| `device.screenSize.width`, `.height` | number | Logical size. Always emitted as a double. |
| `device.screenDensity`, `device.screenPixelDensity` | number | Always emitted as a double. |
| `device.screenDpi` | integer | Screen DPI. |
| `ip.ip` | string | Client IP as known to the host. |
| `ip.city`, `.region`, `.country`, `.timezone`, `.isp`, `.org` | string, optional | IP geolocation facts. |
| `locale.language`, `.country`, `.timezone` | string, optional | Configured device locale. May be `{}`. |
| `configuredUserId` | string or null | Startup user id. Used only by `session_start`. |

`session`: the running session's identity, as the engine holds it.

| Field | Type | Meaning |
| --- | --- | --- |
| `sessionId` | string or null | Collector session id to stamp. For events, `null` means the start handshake has not completed, and the record omits `sessionId`. Required for lifecycle records. |
| `startedAtEpochMs` | integer | Injected clock: session start as Unix epoch milliseconds (UTC). |
| `userId` | string or null | Current runtime user id. |
| `traitsId` | string or null | Collector-issued traits id cached from a prior response. |
| `traits` | object or null | Full traits bag. Lifecycle fixtures only. |

Locale evidence (`event.locale`, `lifecycle.activeLocale`) is the active app
locale. It is evidence, never identity: `language` (required), `country`,
`script`, and `tag` (required BCP 47 tag).

### `collector.sessionLifecycle`

One `POST /v1/sessions` body.

| Input | Meaning |
| --- | --- |
| `host`, `session` | See above. |
| `lifecycle.eventType` | `session_start`, `session_identify`, `session_end`, `traits_updated`, or `user_changed`. Any other string is treated as a non-start record. |
| `lifecycle.triggeredAtEpochMs` | Injected clock: when the record was triggered. |
| `lifecycle.activeLocale` | Locale evidence, optional. Used only by `session_start`. |

| Expected | Meaning |
| --- | --- |
| `record` | The request body object. |

### `collector.event`

One element of `POST /v1/events/batch`.

| Input | Meaning |
| --- | --- |
| `host`, `session` | See above. `session.traits` is not allowed. |
| `event` | One recorded session event (below). |

| Expected | Meaning |
| --- | --- |
| `record` | The event object as placed in the batch. |

`event` is the engine's recorded event: what the session model has already
assembled from adapter facts, before collector mapping. Its form is the JSON
form of the Dart `TugboatEvent`.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Session-unique event id (for example `event-41`). |
| `atMs` | integer | Milliseconds since session start. `triggeredAt` is `startedAtEpochMs + atMs`. |
| `type` | string | `interaction` and `route_change` map to flat records. `network_call` maps to a filtered generic record. Anything else maps to the generic envelope. |
| `stream` | string | `semantic`, `evidence`, or `diagnostic`. |
| `targetAnchor` | object, optional | Resolved target (below). |
| `beforeFrame`, `afterFrame` | string, optional | Frame ids (`frame-<n>`). |
| `result` | string, optional | `changed`, `noVisibleChange`, `navigated`, or `unknown`. Generic envelope only. |
| `relatedEventId` | string, optional | Linked event id. |
| `data` | object, optional | Type-specific facts (below). Defaults to `{}`. |
| `locale` | object, optional | Locale evidence. |
| `explorationRunId`, `actionId` | string, optional | Exploration run and action ids. |

`targetAnchor`:

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | Fingerprint schema of the anchor. Defaults to `1`, and `1` is omitted from output. |
| `widgetType` | string | Toolkit component type name. |
| `role` | string | Actionable role (`button`, `scrollable`, `textField`, and so on). |
| `fingerprint` | string | Target fingerprint (see `fingerprint.identityParts`). |
| `fingerprintConfidence` | string | `high`, `medium`, or `low`. |
| `tagFingerprint` | string | Developer-tag fingerprint. |
| `fingerprintParts` | object of strings | Small serialized evidence (`schemaVersion`, `routeKey`, `tag`), not the hash input. |
| `canonicalPath` | string | Structural path within the route. |
| `relativePosition` | string | `top`, `center`, or `bottom`. |
| `enabled` | boolean | Whether the control is enabled. |
| `actions` | array of strings | Sorted action names. |

`data` for `interaction` (interaction schema 2). Only these keys reach the
wire. Everything else is dropped.

| Key | Meaning |
| --- | --- |
| `interactionSchema` | Defaults to `2` when absent. |
| `gesture` | `tap`, `swipe`, `scroll`, `pan`, `zoom_in`, `zoom_out`, or `cancelled`. Not validated. |
| `route` | Route at pointer down. |
| `targetFingerprint` | Fingerprint of the target (the scrollable for `scroll`). |
| `fingerprintConfidence` | Exploration taps only. |
| `targetResolutionFailureReason` | Closed reason when a tap has no fingerprint. |
| `payload` | Gesture facts, passed through opaquely. `position`, `endPosition`, and `delta` are `{xNorm, yNorm}`. Also `pointerCount`, `scale`, `startOffset`, `endOffset`, and `overscrollCount`. Absent for `cancelled`. |

`data` for `route_change`: the keys listed in `_routeChangeCollectorKeys` in
`collector_mapper.dart` are copied when non-null, and `routeStackTruncated`
only when `true`. `network_call` uses `method`, `route`, `statusCode`,
`outcome`, `durationMs`, `attemptCount`, and `errorResponseBody`. Each one is
kept only when it passes the mapper's type and range checks. For any other
type, `data` is copied into `payload` as-is.

### `evidence.externalEvent` and `evidence.networkCall`

| Input | Meaning |
| --- | --- |
| (the whole `input`) | The message input, exactly as a host sends it, with parameter values and error bodies in the typed value encoding ([evidence messages](../core/session-engine/docs/evidence-messages.md)). |

| Expected | Meaning |
| --- | --- |
| `data` | The recorded event's `data`, or `null` when nothing is recorded. Object key order is compared too, because the data must be byte-identical to Dart's. |

Both runners evaluate the input in a fresh session that started at
`monoUs` 0. A network call begins at `startMonoUs` and finishes at
`endMonoUs` (default the start); an external event happens at `atMonoUs`
(default 0).

- C++ (`tests/conformance/evidence_runner.cpp`): configures a fixed host,
  starts the session, sends the message with `at.monoUs` at the event's
  finish, and reads the one event record.
- Dart (`test/helpers/evidence_fixture.dart`): maps the encoding onto the
  Dart objects a host would pass (`ref` becomes a real cycle, `iterable` a
  non-`List` `Iterable`, `nonStringKeys` fresh `Object` keys, `omitted`
  items unsupported stand-ins, `unsupported` an `Object`, a top-level
  `drop` the transform's drop sentinel) and calls the shipped
  `TugboatEvidenceRecorder` with a transform closure that returns each
  key's sent result. `jsonText` becomes Dio's decode: `jsonDecode`, `null`
  when empty, the raw string when it does not parse.

The full recorded event (id, `atMs`, stream, context ids, no action
context) and the no-session drop are pinned by the `evidence-*` scenarios.

### `engine.scenario`

A scenario drives one fresh engine handle through the stateful protocol
(`core/session-engine/README.md` "Messages").

| Input | Meaning |
| --- | --- |
| `configure` | The `engine.configure` input, sent first. It must be accepted. |
| `steps` | Non-empty array of `{send, expect, note?}`. `send` is one complete message (or `batch`), submitted byte for byte. `note` is for readers only. |

`expect` is either `{records, effects}`, compared with the response's
`records` and `effects`, or `{error: {status, path?}}`, compared with the
error document's `status` and `path` (the message text is not pinned). Every
fact a step sends carries `at`, so a scenario is fully deterministic.

| Expected | Meaning |
| --- | --- |
| `finalSnapshot` | `session.snapshot` after the last step: the session JSON (schema 10), or `null` when no session was ever started. |

The Dart runner (`test/helpers/engine_scenario.dart`) runs every scenario
whose runners include `dart` against the real `TugboatReplayController` and,
with `collector.enabled`, the real `CollectorHttpSink`
(`test/helpers/engine_scenario_delivery.dart`), with their clocks driven by
each step's `at`. Delivery runs on a deterministic scheduler: before each
step, fake time advances to the step's `at.monoUs`, firing every Dart timer
that is due, so a `timer.fired` step needs no Dart call (scenarios fire each
engine timer at its deadline). The sink's requests become `http.send`
effects with runner-minted `http-N` ids, and `transport.result` steps answer
them. A message type or configuration it cannot express is a test failure
that asks for `runners: ["cpp"]`, not a silent pass. It differs from the C++
runner in these documented ways:

- It does not send steps that expect an `error`. Those pin the engine's
  message validation, which Dart's typed API cannot express.
- Until the engine owns capture requests, it compares event ids by first
  appearance rather than by number, in records, snapshots, and request
  bodies: Dart's id counter also mints `capture_request-N` at session start
  and on `resumed`. When capture requests move into the engine, this runner
  must switch to exact ids.
- It compares only `http.send` effects. Dart owns its timers and keeps frame
  bytes until garbage collection, so `timer.*` and `frame.release` have no
  Dart counterpart. JSON bodies are compared byte for byte; `timeoutMs` only
  on frame uploads (Dart puts no timeout on JSON posts, change C3).
- The `TugboatReplay` widget's 500 ms background flush is reproduced by the
  runner, since the widget is not mounted.
- Frames reach the engine only through `capture.result` for an
  interaction's capture request, which the Dart controller cannot drive.
  Scenarios with frames, and scenarios that are `engineOnly` only because
  the engine publishes delivery gaps as records (C6), carry
  `dartParity: "delivery"`: the Dart runner
  (`test/helpers/engine_scenario_replay.dart`) feeds the records each step
  expects (minus the engine's own `collector-…` gap records) into the real
  `CollectorHttpSink` and compares its `http.send` effects, so the 0.10.9
  frame lane (400 isolation, retry offsets, requeue order, the latch, gap
  wire bodies) is cross-checked.

## Determinism

Fixtures contain no ambient state:

- Clock: `startedAtEpochMs` and `triggeredAtEpochMs` are injected integers.
  Event time is `atMs` relative to start. `triggeredAt` is always rendered as
  UTC ISO-8601 with milliseconds (`2026-06-19T00:00:55.957Z`).
- Ids: session, event, frame, run, action, and traits ids are literal
  strings. The engine does not generate them in these operations.
- Scenarios: time comes only from each message's `at`, and the engine mints
  ids from a fresh handle (`session-<wallUs>`, `event-N` from 0), so the
  same steps always produce the same records.
- Session and app metadata: everything comes from `host` and `session`.
  Transport settings are not inputs.
- Contract constants (`interactionSchema` 2, `routeChangeSchema` 2,
  `fingerprintSchemaVersion` 6) are outputs, not inputs.

## Comparison

A runner compares `expected` with its actual output as type-strict deep JSON
equality:

- Object key order is not significant. Array order is.
- An absent key differs from a key whose value is `null`. For example,
  `userId: null` is always present on event records.
- Integers and non-integral numbers are distinct: `390` does not equal
  `390.0`. Fixtures record doubles the way Dart encodes them (`390.0`,
  `-0.6000000000000001`).
- Strings compare by code point, with no Unicode normalization.

Byte-level serialization (key order, whitespace, number formatting beyond the
integer/double distinction) is not pinned yet.

## Versioning

Every fixture pins `contract.sessionSchemaVersion` (`10`) and
`contract.fingerprintSchemaVersion` (`6`). The Dart runner fails every fixture
when `tugboatSessionSchemaVersion` or `tugboatFingerprintSchemaVersion`
changes. Bumping either one therefore forces each fixture to be re-reviewed and
re-pinned, and a fixture never carries over to a new contract silently.
Changing the envelope itself bumps `fixtureFormat`.

## Fixtures are reviewed artifacts

Committed fixtures are the source of truth. Tests assert against them and
never write to this folder. Nothing regenerates them automatically.

To add or change a fixture:

1. Write or edit the JSON by hand: envelope, `description`, and `input`. For
   a new fixture, set `"expected": {}`.
2. Run `dart run melos run test:sdk`, or just
   `flutter test test/conformance_fixtures_test.dart` inside
   `sdks/flutter/packages/tugboat`. A mismatch prints one line per differing
   JSON path, followed by the actual value in fixture formatting.
3. Review the actual value as a contract change (see `AGENTS.md`), then paste
   it into `expected`. A changed `expected` in a diff is a wire or identity
   change and needs the same review as a schema change.

Dart runner: `sdks/flutter/packages/tugboat/test/conformance_fixtures_test.dart`.
The loader in `test/helpers/conformance_fixture.dart` is the reference reader
for this format, and `test/helpers/engine_scenario.dart` runs scenarios. It also binds the identity-parts hash to the real Flutter
resolver, so the vectors cannot drift from the private Dart implementation.
