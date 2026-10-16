# Evidence messages: external events and network calls

Status: Accepted · 2026-10-16 · native evidence slice N1

`evidence.externalEvent` and `evidence.networkCall` move Flutter's coded-event
and network-call evidence into the engine
([stateful design](stateful-engine.md) section 4.3.1). The engine applies the
parameter policy, every limit, label bounding, method and route
normalization, error-body normalization, and the duration arithmetic, once,
in C++. Hosts keep only what needs the host's runtime:

- running a `transform` policy's closure;
- converting typed values into the value encoding below;
- reading an error response body from the transport.

The reference is the Dart implementation in `package:tugboat`
(`external_event.dart`, `network_observer.dart`, `evidence_recorder.dart`).
The event `data` is byte-identical to what Dart records for the same input.
The `conformance/evidence/` fixtures pin that equality, and both the C++
runner and the Dart runner run them. Dart keeps its own implementation until
Flutter moves onto the engine (Q1).

## 1. Messages

Both are event-producing: without a live session the dispatcher drops them
and records nothing. Both record on the `evidence` stream, and neither
inherits an action context (`attachActionContext: false`, section 4.4).

### `evidence.externalEvent`

`{name, source?, policy, parameters?, atMonoUs?}`

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | Event name, sent in full. Trimmed (Dart `String.trim`) and cut to 256 UTF-16 code units. Empty after trimming: nothing is recorded. |
| `source` | string, optional | Hook source, sent in full. Trimmed and cut to 128 units. Empty after trimming: omitted. |
| `policy` | object | `{mode, allowedKeys?}`. `mode` is `names_only`, `allow_list`, `transform`, or `allow_all`. `allowedKeys` (array of strings) is required with `allow_list` and not allowed otherwise. |
| `parameters` | value, optional | A `map` value (section 2) holding the parameters, with the rules in section 3.1. Absent, `null`, or a map without entries: no parameters. |
| `atMonoUs` | integer, optional | Fact time. Default `at.monoUs`. |

The recorded `external_event` data is, in this key order:
`source?`, `name`, `parameterKeys`, `parameters?`,
`capture {values, truncated, droppedCount}`.

### `evidence.networkCall`

`{method, route, startMonoUs, endMonoUs?, statusCode?, outcome, attemptCount?, errorResponseBody?}`

| Field | Type | Meaning |
| --- | --- | --- |
| `method` | string | Request method as the host has it. Trimmed and upper-cased. Empty, longer than 16 units, or holding a non-ASCII character after trimming: nothing is recorded. |
| `route` | string | The host's route resolver output, untrimmed. It must be an absolute path of at most 256 units: no surrounding whitespace, no `//` prefix, no `://`, and no control character, space, DEL, `%`, `#`, `?`, or `\`. Otherwise nothing is recorded (Dart's no-op token). |
| `startMonoUs` | integer | Host monotonic time when the call began. It is the event's fact time, so the event keeps its start (change C19). A call that began before the live session started is dropped, as Dart drops a token from an earlier session. |
| `endMonoUs` | integer, optional | When the call finished. Default `at.monoUs`. |
| `statusCode` | integer, optional | HTTP status. Recorded when present. |
| `outcome` | string | `response`, `network_error`, or `cancelled`. |
| `attemptCount` | integer, optional | Recorded only when greater than 0. |
| `errorResponseBody` | object, optional | `{"value": <value>}` or `{"jsonText": "<text>"}` (section 3.2). Used only when `statusCode` is 400 or more; otherwise ignored. |

`durationMs` is `floor((end - sessionStart) / 1000) - floor((start -
sessionStart) / 1000)`, clamped to `[0, 86400000]`: Dart subtracts two
`Stopwatch.elapsedMilliseconds` readings.

The recorded `network_call` data is, in this key order: `method`, `route`,
`statusCode?`, `outcome`, `durationMs`, `attemptCount?`,
`errorResponseBody?`, `errorResponseBodyCapture? {format, representation,
truncated}`.

### Lengths

Wherever Dart measures `String.length`, the engine counts UTF-16 code units
(a code point above U+FFFF counts 2). Cutting at a unit count can split a
surrogate pair; the engine keeps the lone high surrogate, as Dart does, and
writes it as a `\uXXXX` escape (Dart's `jsonEncode` escapes unpaired
surrogates). Wherever Dart measures `utf8.encode(...).length`, the engine
counts UTF-8 bytes, with a lone surrogate counting 3 (Dart encodes it as
U+FFFD).

## 2. Value encoding

Parameter values and error bodies are host-typed values. A host writes each
one as JSON in this grammar. It is unambiguous whatever JSON writer the host
uses, because no meaning depends on number formatting or object key order:

| Host value | Encoding |
| --- | --- |
| null | `null` |
| boolean | `true` / `false` |
| string | a JSON string. A lone surrogate is written as a `\uXXXX` escape. |
| integer (64-bit) | a JSON integer literal (no fraction, no exponent, within int64) |
| floating point | `{"double": <JSON number>}`, or `{"double": "NaN" \| "Infinity" \| "-Infinity" \| "-0.0"}` |
| list (Dart `List`) | a JSON array, or `{"list": [ ... ], "omitted": n}` when the host sends only the first items |
| any other iterable (Dart non-`List` `Iterable`, such as a set) | `{"iterable": [ ... ], "omitted"?: n}` |
| map | `{"map": [entry, ...], "omitted"?: n}`, entries in host order (section 4) |
| an ancestor collection (a cycle) | `{"ref": n}`: the collection `n` levels up, `1` being the collection that directly contains this value |
| anything else (not a JSON type) | `{"unsupported": true}` |
| transform drop sentinel | `{"drop": true}`: only as a top-level parameter value under `transform` |

Map entries:

- `[key, value]`: `key` is a JSON string.
- `{"nonStringKeys": n}`: `n` (≥ 1) consecutive entries whose keys are not
  strings. Their values are never read, so they are not sent.

Rules:

- Every JSON object in a value is one of the tags above, with exactly that
  tag's keys. A bare JSON number must be an integer within int64: write a
  double as `{"double": 1.0}` even when the writer prints `1`. Negative
  zero is `{"double": "-0.0"}`, since writers print it as `0` or `-0`, which
  read as the integer 0.
- `omitted` is a count ≥ 1 of items or entries after the sent ones.
- `ref` counts collections within the value. For parameters, the top-level
  parameters map is not a collection of any value: a value that is the
  parameters map itself is written out once as an ordinary map. Cycles are
  identity: a collection is an ancestor when it is the same instance, not an
  equal one.
- `drop` anywhere else, an unknown tag, a bad count, or a `ref` above the
  value's root is an invalid message.

Items the host did not send (`omitted`) are evaluated as unsupported values,
and omitted map entries as string-keyed entries with unsupported values. The
elision rules in section 4 only omit items Dart never reaches, so that stand-in
is exact.

## 3. Engine semantics

### 3.1 Parameters (Dart `snapshotExternalParameters`)

- Only the first 64 entries are considered. Each further entry (`omitted` on
  the parameters map) adds 1 to `droppedCount` and sets `truncated`.
- A key is valid when it is a string of 1 to 128 units. An invalid key adds 1
  to `droppedCount`, sets `truncated`, and is not listed.
- Valid keys are listed in `parameterKeys` in order. The policy then decides
  the value:
  - `names_only`: the value is not read, and `parameters` is omitted.
  - `allow_list`: a key outside `allowedKeys` adds 1 to `droppedCount`
    (without `truncated`) and its value is not read.
  - `transform`: the sent value is the transform's result; `{"drop": true}`
    adds 1 to `droppedCount` without `truncated`.
  - `allow_all`: the value is kept.
- Kept values are copied at depth 1 (a nested value is one deeper). Each of
  these adds 1 to `droppedCount`, sets `truncated`, and leaves the value out:
  a value deeper than 4; a non-finite double; a string longer than 1024
  units; an unsupported value; a `ref` (cycle); a nested entry whose key is
  invalid.
- Collection items (map entries with valid keys, and list or iterable items)
  share one budget of 256 across the whole event. The first item over budget
  in a collection adds 1 to `droppedCount`, sets `truncated`, and ends that
  collection.
- A map, list, or iterable that is kept stays in the output (possibly empty).
  An iterable is copied as a list.
- `parameters` is omitted when no value was kept.
- When the kept values, as Dart's `jsonEncode`, exceed 16384 UTF-8 bytes, all
  of them are left out: `parameters` is omitted, `droppedCount` grows by the
  number of kept keys, and `truncated` is set.

### 3.2 Error body (Dart `snapshotNetworkErrorResponseBody`)

Only for `statusCode` ≥ 400. `{"value": v}` is the body as Dart receives it:

- `null` or unsupported: no body.
- A string: `format: text`. Kept whole when its UTF-8 length is at most 4096
  bytes. Otherwise the longest prefix of whole code points within 4096 bytes,
  with `truncated: true`.
- Anything else is normalized at depth 0. Strings, booleans, `null`, and
  integers are kept; a non-finite double is unsupported. A list or map
  deeper than depth 5, an iterable, or an unsupported value is unsupported.
  Lists and maps keep their first 128 items (a non-string key uses up one of
  them). An unsupported item, a non-string key, or more than 128 items sets
  `truncated`. Cycles (`ref`) are followed until the depth limit, as Dart
  has no cycle check here. An unsupported root means no body.
- The normalized value, as `jsonEncode`, at most 4096 UTF-8 bytes:
  `format: json`, `representation: native`, the value, and its `truncated`.
- Longer: `format: json`, `representation: serialized_prefix`, the longest
  prefix of whole code points of that encoding within 4096 bytes, and
  `truncated: true`. The engine stops normalizing once its encoding passes
  4096 bytes.

`{"jsonText": t}` is a body the host did not decode. The engine decodes it
as Dart's `jsonDecode` does (duplicate keys keep the first position and the
last value) and continues as for `{"value": ...}`. Empty text means no body,
as Dio returns `null` for an empty JSON response. Text that is not valid
JSON, or nests deeper than 512, is treated as `{"value": t}` (a text body).

Error-body `representation` is `native` except for `serialized_prefix`.

## 4. Host obligations

Kotlin (`tugboat-android`) and Swift (`Tugboat`) implement exactly this.
Anything not listed stays in the engine.

### 4.1 Typed values

- Kotlin: `null` → `null`; `Boolean`; `String`; `Byte`, `Short`, `Int`,
  `Long` → integer; `Float`, `Double` → `double` (`Float` widened);
  `List` → list; any other `Iterable`/`Collection` (a `Set`) → `iterable`;
  `Array<*>` → list; `Map` → map; everything else, including `Char`,
  `BigInteger`, `BigDecimal`, primitive arrays, and the drop sentinel nested
  inside a value, → `unsupported`.
- Swift: `nil`/`NSNull` → `null`; `Bool` (and a boolean `NSNumber`) →
  boolean; `String` → string; signed and unsigned integers that fit in
  `Int64` → integer (larger `UInt64` → `unsupported`); `Double`, `Float`,
  `CGFloat` (and a floating `NSNumber`) → `double`; `Array`/`NSArray` →
  list; `Set`/`NSSet` → `iterable`; `Dictionary`/`NSDictionary` → map;
  everything else, including `Character`, `Decimal`, `Data`, `Date`, and the
  drop sentinel nested inside a value, → `unsupported`.
- Lone surrogates (Kotlin strings can hold them) must be written as
  `\uXXXX`; `org.json` writes them raw, and the UTF-8 conversion then
  replaces them. Swift strings cannot hold them.

### 4.2 Map order

The engine keeps the host's order, and Dart's limits depend on it.

- Kotlin: the map's own iteration order (`LinkedHashMap` insertion order, as
  in Dart; other maps' iteration order as they define it).
- Swift: dictionaries have no order, so hosts sort string keys by Swift
  `String` `<`, at the top level and in every nested map, followed by one
  `nonStringKeys` run for the remaining keys. This order is host-defined:
  Dart has no equivalent, and a Swift event can differ from a Kotlin or Dart
  one with the same keys when a limit cuts the map.

### 4.3 The transform contract

Under `transform` the host calls the closure exactly once for each entry
among the first 64, in order, whose key is valid (a string of 1 to 128
UTF-16 units: Kotlin `String.length`, Swift `key.utf16.count`), and never for
any other entry. It sends the result as the entry's value: the encoded
return value, or `{"drop": true}` when the closure returned the drop
sentinel or threw. Entries with invalid keys are sent with value `null`.
The engine applies everything else (the policy mode label, limits,
encoding).

### 4.4 Required bounds

These keep messages within the engine's default nesting depth (64):

- Parameters: a value at depth 5 or more (top-level values are depth 1)
  is sent as `{"unsupported": true}`.
- Error bodies: a list, map, or iterable at depth 6 or more (the root is
  depth 0) is sent as `{"unsupported": true}`. Strings, numbers, booleans,
  and `null` at that depth are still sent.
- Cycles are sent as `ref`.

### 4.5 Elision (optional, exact)

A host may omit what Dart never reads. Every rule keeps the event
byte-identical:

- Parameters, top level: send the first 64 entries, then `omitted` = the
  exact number of further entries (Dart counts them all). `omitted` on the
  parameters map requires 64 sent entries.
- Values the engine never reads may be sent as `null`: every value under
  `names_only`, values of keys outside `allowedKeys` under `allow_list`, and
  values of invalid keys.
- Parameters, nested: a string longer than 1024 units may be sent as
  `{"unsupported": true}`. An entry whose key is a string that is empty or
  longer than 128 units may be folded into a `nonStringKeys` run. A list or
  iterable may stop after its 257th item, and a map after its 257th entry
  with a valid key (the item budget ends it by then), without `omitted`.
- Error bodies: a list, map, or iterable may send its first 128 items with
  `omitted` ≥ 1 (any count). A string or key may be cut to its first 4097
  UTF-16 units. A text body may be cut to any prefix longer than 4096 UTF-8
  bytes (whole characters only; a byte-oriented host decodes the first 4100
  bytes and drops a trailing partial character). A host may stop writing a
  `value` body after it has written 4097 lists, maps, strings, numbers,
  booleans, or `null`s (not counting `unsupported`, `ref`, `iterable` and its
  contents, or map entries with non-string keys), closing the open
  collections, because Dart's encoding is then past 4096 bytes.
- Error bodies for status codes below 400 are never read: do not read or
  send them.

Not elided: `name` and `source` are sent in full (trimming needs both ends),
and `jsonText` must be the complete body to be exact.

### 4.6 Tokens and timing (unchanged host work)

The host's network-call token keeps `startMonoUs` from the host monotonic
clock (section 5) at begin, sends one `evidence.networkCall` on the first
`complete`/`fail`, and ignores later ones. Method and route validity are
decided by the engine at that point, so a token always looks live to the
app. Failures never reach the app: encoding errors drop the evidence.
