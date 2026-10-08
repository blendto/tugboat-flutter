# Conformance fixtures

Language-neutral golden fixtures for the session engine described in
[ADR 0009](../docs/decisions/0009-shared-session-engine.md). Each fixture
gives the facts a toolkit adapter or platform host submits and the exact
record the engine must produce. The current Dart implementation in
`package:tugboat` must match every fixture, and so must the C++ engine when it
exists. These fixtures are what keeps the two equivalent.

This folder is outside the pub package on purpose: it is never published to
pub.dev and no runtime reads it.

Scope of this first slice: pure mapping and hashing only. These are fingerprint
hashing of supplied identity parts and collector record mapping for one event
or one session lifecycle record. Controller orchestration (interaction
transactions, dedup, batching, delivery gaps) is not covered yet.

## Layout

```text
conformance/
  README.md
  fingerprint/
    identity_parts/<name>.json      kind fingerprint.identityParts
    label_hash/<name>.json          kind fingerprint.labelHash
  collector/
    event/<name>.json               kind collector.event
    session_lifecycle/<name>.json   kind collector.sessionLifecycle
```

One case per file. The file name stem equals the fixture `name`, and the
directory is fixed by `kind`. A runner loads every `*.json` under
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

## Determinism

Fixtures contain no ambient state:

- Clock: `startedAtEpochMs` and `triggeredAtEpochMs` are injected integers.
  Event time is `atMs` relative to start. `triggeredAt` is always rendered as
  UTC ISO-8601 with milliseconds (`2026-06-19T00:00:55.957Z`).
- Ids: session, event, frame, run, action, and traits ids are literal
  strings. The engine does not generate them in these operations.
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
for this format. It also binds the identity-parts hash to the real Flutter
resolver, so the vectors cannot drift from the private Dart implementation.
