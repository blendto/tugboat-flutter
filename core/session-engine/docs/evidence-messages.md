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
| `parameters` | value, optional | A `map` value (section 2) holding the parameters, written by the rules in section 4.4 and read by section 3.1. Absent, `null`, or a map without entries: no parameters. |
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
| `errorResponseBody` | object, optional | `{"value": <value>}` or `{"jsonText": "<text>"}` (section 3.2). Read only when `statusCode` is 400 or more. It is validated either way: an invalid body rejects the message. |

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
  strings. Their values are never read, so they are not sent. In parameters
  it also stands for keys that are strings but invalid (section 4.4).

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
- A repeated key is invalid in a parameters map. In an error body map it is
  kept in order (a host's cut can make two long keys equal, section 4.5).
- `drop` anywhere else, an unknown tag, a bad count, or a `ref` above the
  value's root is an invalid message, wherever it appears: an invalid
  `errorResponseBody` rejects the message even when `statusCode` is below
  400. Hosts never send one.

Items the host did not send (`omitted`) are evaluated as unsupported values,
and omitted map entries as string-keyed entries with unsupported values. The
rules in section 4 only omit items Dart never reaches, so that stand-in is
exact.

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

Read only for `statusCode` ≥ 400 (below that it is still validated).
`{"value": v}` is the body as Dart receives it:

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
as Dart's `jsonDecode` does: repeated keys keep the first position and the
last value, lone surrogates in strings are kept, and nesting has no limit
(subtrees below the depth Dart reads are checked and skipped). It then
continues as for `{"value": ...}`. Empty text means no body, as Dio returns
`null` for an empty JSON response. Text that is not valid JSON is treated as
`{"value": t}` (a text body).

Error-body `representation` is `native` except for `serialized_prefix`.

## 4. Host obligations

Kotlin (`tugboat-android`) and Swift (`Tugboat`) implement exactly this.
Anything not listed stays in the engine. Sections 4.4 and 4.5 are
mandatory: they bound the host's own work and the message size, and each
rule only leaves out what Dart never reads, so the event stays
byte-identical.

### 4.1 Typed values

- Kotlin: `null` → `null`; `Boolean`; `String`; `Byte`, `Short`, `Int`,
  `Long` → integer; `Float`, `Double` → `double` (`Float` widened);
  `List` → list; any other `Iterable`/`Collection` (a `Set`) → `iterable`;
  `Array<*>` → list; `Map` → map; everything else, including `Char`,
  `BigInteger`, `BigDecimal`, primitive arrays, and the drop sentinel nested
  inside a value, → `unsupported`.
- Swift: classify an `Any` in this order, so bridging cannot change the
  answer:
  1. `nil`, `Optional.none`, or `NSNull` → `null`.
  2. `NSNumber` (every bridged `Bool`, integer, and floating value lands
     here; test it before the Swift types): if
     `CFGetTypeID(n) == CFBooleanGetTypeID()` → boolean; else if
     `CFNumberIsFloatType(n)` → `double` (`n.doubleValue`); else an integer:
     `n.int64Value` when it represents the value exactly (for a `UInt64`
     above `Int64.max` it does not) → integer, otherwise `unsupported`.
  3. `Bool` → boolean; `Int`, `Int8`…`Int64`, `UInt`, `UInt8`…`UInt64` →
     integer when it fits in `Int64`, otherwise `unsupported`; `Double`,
     `Float`, `CGFloat` → `double`.
  4. `String` → string.
  5. `Array`/`NSArray` → list; `Set`/`NSSet` → `iterable`;
     `Dictionary`/`NSDictionary` → map.
  6. Everything else, including `Character`, `Decimal`, `Data`, `Date`, and
     the drop sentinel nested inside a value, → `unsupported`.

  An analytics parameter `1.0` (a floating `NSNumber`) is a `double`, never
  the integer `1`.
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

"Visit order" below is this order, depth first: a collection's items in
order, each item's own contents before the next item.

### 4.3 The transform contract

Under `transform` the host calls the closure exactly once for each entry
among the first 64, in order, whose key is valid (a string of 1 to 128
UTF-16 units: Kotlin `String.length`, Swift `key.utf16.count`), and never for
any other entry. It sends the result as the entry's value: the encoded
return value, or `{"drop": true}` when the closure returned the drop
sentinel or threw. Entries with invalid keys go into `nonStringKeys` runs.
Entries after the 64th are never sent (section 4.4); if a host sends them
anyway, their values are never read. The engine applies everything else (the
policy mode label, limits, encoding).

### 4.4 Parameters

Keys:

- A key is valid when it is a string of 1 to 128 UTF-16 units. Consecutive
  entries with invalid keys (not strings, empty, or longer) are sent as one
  `{"nonStringKeys": n}` run, at every level.

Top level:

- Send the first 64 entries (a run counts each entry it stands for), then
  `omitted` = the exact number of further entries. Dart counts them all.
- A value the engine never reads is sent as `null` and is not encoded: every
  value under `names_only`, and the values of keys outside `allowedKeys`
  under `allow_list`.

Inside each value that is read (top-level values are depth 1):

- A value at depth 5 or more is sent as `{"unsupported": true}`, without
  reading it.
- A string longer than 1024 UTF-16 units is sent as `{"unsupported": true}`.
- Item budget. The host keeps one counter `c`, starting at 0, for the whole
  parameters tree. Walking the read values in visit order, a counted slot is
  a list or iterable item, or a map entry whose key is valid (run entries are
  never counted). At each counted slot:
  - if `c` is below 256: `c += 1`, then send the slot (encoding its value,
    which may count further slots);
  - if `c` is 256: send `"omitted": 1` on this collection and stop sending
    it. Nothing after that slot in this collection is read.

  Later collections follow the same rule, so after the budget each one sends
  its leading run (if any) and `"omitted": 1` at its first counted slot, or
  is empty. The walk never descends into more than 256 items.

### 4.5 Error bodies

Sources:

- A decoded value the app passes to `complete`/`fail` (the manual API):
  `{"value": <encoded value>}` with the rules below. A string is a text
  body.
- A byte-reading adapter (OkHttp, URLSession; slice N2) peeks at most 64 KiB
  of the body, never consuming it:
  - when the peek holds the complete body and `Content-Type` is JSON
    (`application/json` or a `+json` subtype), send `{"jsonText": <body
    decoded as UTF-8>}`;
  - otherwise send `{"value": <the decoded text>}`, cut to the complete
    characters of the first 4100 bytes (any prefix longer than 4096 UTF-8
    bytes keeps the text body exact).

  So a JSON body over 64 KiB is recorded as `text` where Dio would record a
  json `serialized_prefix`. Both are cut to 4096 bytes; only bodies Dart
  truncates anyway are affected.
- Bodies for status codes below 400 are never read or sent.

Encoding a value body (the root is depth 0):

- A list, map, or iterable at depth 6 or more is sent as
  `{"unsupported": true}`. Strings, numbers, booleans, and `null` at that
  depth are still sent.
- Per collection: send only the first 128 items (a map's first 128 entries,
  each non-string key counting as one entry of its run), then
  `"omitted": n` with `n ≥ 1` when there are more. Items past the 128th are
  never read.
- A string or a key longer than 4097 UTF-16 units is cut to its first 4097
  units. A cut can make two keys equal; the engine keeps both.
- Node budget. The host counts the nodes it writes within those caps, in
  visit order: every list, map, string, finite number, boolean, and `null`
  it sends, except anything inside an `iterable` and the values under
  non-string keys (which are not sent). `unsupported`, non-finite doubles,
  and `ref` are not counted. When the count reaches 4097, the host stops:
  it writes nothing more and closes the open collections. Each counted node
  adds at least one byte to Dart's encoding, so the encoding is past 4096
  bytes before the cut.

Not elided: `name` and `source` are sent in full (trimming needs both ends),
and `jsonText` must be the complete body.

### 4.6 Tokens and timing (unchanged host work)

The host's network-call token keeps `startMonoUs` from the host monotonic
clock (section 5) at begin, sends one `evidence.networkCall` on the first
`complete`/`fail`, and ignores later ones. Method and route validity are
decided by the engine at that point, so a token always looks live to the
app. Failures never reach the app: encoding errors drop the evidence.
