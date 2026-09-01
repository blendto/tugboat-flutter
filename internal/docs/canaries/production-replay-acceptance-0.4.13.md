# Production replay acceptance: 0.4.12 → 0.4.13

Use this after shipping SDK **0.4.13** (and collector build passthrough) and
running Blend through a similar flow to the baseline session.

## Baseline (locked)

| Field | Value |
| --- | --- |
| Session | redacted |
| SDK | `0.4.12` |
| App | Blend Android |
| Build | redacted |

| Metric | Baseline |
| --- | ---: |
| Raw `tap` | 86 |
| Swipe-consumed taps | 63 |
| Settled taps | 23 |
| Truly orphaned taps | 0 |
| `tap_settled` `result=unknown` | 6 |
| unknown `superseded_route_epoch` | 2 |
| `missing_frame` with zero local/normalized | 1 |
| `capture_diagnostic` `missing_context_graph_build_identity` | 37 / 37 |

## Manual run checklist

1. Install / point Blend at tugboat **0.4.13** (includes same-turn claims,
   deferred taps, session-end pointer fence, duplicate-down coalesce).
2. Confirm collector with event `build` passthrough is deployed (Gate 8).
3. Drive: scroll/flick on home, Get Pro / paywall, StageIt / sheet / chooser,
   one rapid double-tap during settle.
4. Paste the new `sessionId` (+ Blend build) in chat for scoring.

## Hard gates (all must PASS)

1. **Identity** — `metadata.sdkVersion = '0.4.13'` on event groups.
2. **No phantom taps** — `swipe_consumed_taps = 0`.
3. **Settle coverage** — `settled / raw_taps >= 0.95`.
4. **No same-position bursts** — no UTC second with `tap_count >= 5` and
   `distinct_positions = 1`.
5. **Unknown settles** — `unknown / tap_settled <= 0.10` **and**
   `superseded_route_epoch` count = 0.
6. **After frames** — 100% of `navigated`/`changed` settles have `afterFrame`.
7. **Missing-frame geometry** — any `missing_frame` tap has
   `normalizedX/Y ∈ [0,1]` and `boundaryWidth/Height > 0`.
8. **Diagnostics identity** — zero
   `missing_context_graph_build_identity` on `capture_diagnostic`
   (BLOCKED if collector not deployed).
9. **Swipe start geometry** — every `swipe` has `payload.startCaptureCoordinate`.

Overall verdict: **ACCEPT** only if every gate PASSes; otherwise **REJECT** or
**BLOCKED** with the first failing gate id.

## ClickHouse queries

Replace `{newSession}` with the new session id. Service: pmkit ClickHouse.

### Gate 1 — SDK version

```sql
SELECT
  argMax(metadata.sdkVersion::Nullable(String), receivedAt) AS sdkVersion,
  count() AS rows
FROM pmkit.raw_events
WHERE sessionId = {newSession}
GROUP BY eventType
ORDER BY eventType
```

### Gates 2–3 — tap fate

```sql
WITH events AS (
  SELECT id,
    argMax(eventType, receivedAt) AS eventType,
    argMax(metadata.relatedEventId::Nullable(String), receivedAt) AS related
  FROM pmkit.raw_events
  WHERE sessionId = {newSession}
  GROUP BY id
),
taps AS (SELECT id FROM events WHERE eventType = 'tap'),
swipeRefs AS (SELECT related FROM events WHERE eventType = 'swipe' AND related IS NOT NULL),
settleRefs AS (SELECT related FROM events WHERE eventType = 'tap_settled' AND related IS NOT NULL)
SELECT
  count() AS totalTaps,
  countIf(id IN (SELECT related FROM swipeRefs)) AS consumedBySwipe,
  countIf(id IN (SELECT related FROM settleRefs)) AS settled,
  countIf(
    id NOT IN (SELECT related FROM swipeRefs)
    AND id NOT IN (SELECT related FROM settleRefs)
  ) AS orphaned
FROM taps
```

### Gate 4 — bursts

```sql
WITH taps AS (
  SELECT
    argMax(triggeredAt, receivedAt) AS triggeredAt,
    argMax(payload.x::Nullable(Float64), receivedAt) AS x,
    argMax(payload.y::Nullable(Float64), receivedAt) AS y
  FROM pmkit.raw_events
  WHERE sessionId = {newSession} AND eventType = 'tap'
  GROUP BY id
)
SELECT
  toStartOfSecond(triggeredAt) AS sec,
  count() AS tapCount,
  uniqExact((round(x, 1), round(y, 1))) AS distinctPositions
FROM taps
GROUP BY sec
HAVING tapCount >= 5 AND distinctPositions = 1
ORDER BY sec
```

### Gate 5 — unknown settles

```sql
WITH settles AS (
  SELECT
    argMax(result, receivedAt) AS result,
    argMax(toJSONString(payload), receivedAt) AS payloadJson
  FROM pmkit.raw_events
  WHERE sessionId = {newSession} AND eventType = 'tap_settled'
  GROUP BY id
)
SELECT
  count() AS totalSettled,
  countIf(result = 'unknown') AS unknownSettles,
  countIf(
    JSONExtractString(payloadJson, 'settleObservation', 'captureFailure')
      = 'superseded_route_epoch'
  ) AS supersededRouteEpoch
FROM settles
```

### Gate 6 — after frames on navigated/changed

```sql
WITH settles AS (
  SELECT
    argMax(result, receivedAt) AS result,
    argMax(afterFrame, receivedAt) AS afterFrame
  FROM pmkit.raw_events
  WHERE sessionId = {newSession} AND eventType = 'tap_settled'
  GROUP BY id
)
SELECT
  countIf(result IN ('navigated', 'changed')) AS outcomeRows,
  countIf(result IN ('navigated', 'changed') AND afterFrame IS NULL) AS missingAfter
FROM settles
```

### Gate 7 — missing_frame geometry

```sql
WITH taps AS (
  SELECT argMax(toJSONString(payload), receivedAt) AS payloadJson
  FROM pmkit.raw_events
  WHERE sessionId = {newSession} AND eventType = 'tap'
  GROUP BY id
)
SELECT
  JSONExtractString(payloadJson, 'captureCoordinate', 'unavailableReason') AS reason,
  JSONExtractFloat(payloadJson, 'captureCoordinate', 'normalizedX') AS nx,
  JSONExtractFloat(payloadJson, 'captureCoordinate', 'normalizedY') AS ny,
  JSONExtractFloat(payloadJson, 'captureCoordinate', 'boundaryWidth') AS bw,
  JSONExtractFloat(payloadJson, 'captureCoordinate', 'boundaryHeight') AS bh
FROM taps
WHERE JSONExtractString(payloadJson, 'captureCoordinate', 'unavailableReason')
  = 'missing_frame'
```

### Gate 8 — diagnostics enrichment

```sql
WITH diags AS (
  SELECT argMax(toJSONString(payload), receivedAt) AS payloadJson
  FROM pmkit.raw_events
  WHERE sessionId = {newSession} AND eventType = 'capture_diagnostic'
  GROUP BY id
)
SELECT
  count() AS diagnostics,
  countIf(
    JSONExtractString(payloadJson, 'contextEnrichment', 'reason')
      = 'missing_context_graph_build_identity'
  ) AS missingBuildIdentity
FROM diags
```

### Gate 9 — swipe startCaptureCoordinate

```sql
WITH swipes AS (
  SELECT argMax(toJSONString(payload), receivedAt) AS payloadJson
  FROM pmkit.raw_events
  WHERE sessionId = {newSession} AND eventType = 'swipe'
  GROUP BY id
)
SELECT
  count() AS swipes,
  countIf(JSONHas(payloadJson, 'startCaptureCoordinate')) AS withStartCoord
FROM swipes
```

## Deliverable

After scoring, write
`docs/integration/production-replay-compare-0.4.12-vs-0.4.13.md` with:

- session ids + SDK versions
- side-by-side metric table
- per-gate PASS/FAIL with deciding counts
- single overall `ACCEPT` / `REJECT` / `BLOCKED`
