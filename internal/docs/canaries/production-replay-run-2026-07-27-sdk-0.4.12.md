# Production replay run report: SDK 0.4.12

Date: 2026-07-27
Source: ClickHouse production tables
Session under analysis: redacted
SDK version: `0.4.12`
App: Blend Android
Blend version/build: redacted
Device platform: Android

## Verdict

The session did ingest as SDK `0.4.12`, and the new capture diagnostics show
that route, modal, and fresh-frame capture are active in production. The run is
not yet a replay-quality pass. The remaining failures are concentrated around
tap volume, tap settlement coverage, missing settled frames, and at least one
missing-frame coordinate fallback.

The next SDK fix should focus on tap deduplication / gesture coalescing and
raising `tap_settled` coverage for real taps. The dashboard should not paper
over these symptoms as a successful replay, because the SDK is still emitting
ambiguous interaction evidence.

## Identity and timing

| Field | Value |
| --- | --- |
| Session ID | redacted |
| SDK version | `0.4.12` |
| App ID | Blend Android |
| Blend build | redacted |
| First event | `2026-07-27 08:57:03.932 UTC` |
| Last event | `2026-07-27 09:02:33.456 UTC` |
| Session received | `2026-07-27 08:57:08.619 UTC` |
| Total raw events | `249` |
| Unique event IDs | `249` |
| Referenced frames | `28` |

Note: a later session on SDK `0.4.0` was present and excluded from this verdict.

## Event summary

| Event type | Rows | With before frame | With after frame | Notes |
| --- | ---: | ---: | ---: | --- |
| `session_start` | 1 | 0 | 0 | Correctly marked SDK `0.4.12` |
| `capture_diagnostic` | 37 | 0 | 29 | New diagnostic stream is present |
| `route_change` | 16 | 0 | 16 | Route evidence has destination frames |
| `tap` | 86 | 85 | 0 | Raw tap volume is high |
| `tap_settled` | 23 | 23 | 17 | Only 23 of 86 taps settled |
| `state_change` | 12 | 12 | 9 | Some changes lack after frames |
| `swipe` | 64 | 63 | 0 | Large gesture volume in the run |
| `scroll_start` | 3 | 1 | 0 | Limited scroll lifecycle coverage |
| `scroll_end` | 3 | 1 | 1 | Limited scroll lifecycle coverage |
| `app_inactive` | 2 | 0 | 0 | Lifecycle events captured |
| `app_foregrounded` | 2 | 0 | 0 | Lifecycle events captured |

## What improved

- SDK version propagation worked for this session. All event groups reported
  `metadata.sdkVersion = 0.4.12`.
- Route observation was active. The run captured `/home`,
  `/subscriptionPaywall`, `/stageit/recents`, `/aiStudio/upload`,
  `/imageChooser`, `/stageit/image`, and `aiStudio/videos/anyImage`.
- Bottom sheet observation was active. The run captured
  `ModalBottomSheetRoute<StageItGenInputBottomsheetValue>`.
- Route captures consistently had `afterFrame` evidence: 16 route changes,
  16 with `afterFrame`.
- Capture diagnostics are now useful production evidence. The session included
  fresh route, tap, lifecycle, scroll, and initial capture diagnostics.
- Tap coordinates are mostly emitted in capture-boundary local logical space:
  85 of 86 taps had `sourceSpace = boundaryLocalLogical`.

## Remaining failures

### 1. Tap settlement coverage is too low

There were 86 raw `tap` events, but only 23 `tap_settled` events linked back to
those taps. That leaves 63 taps without a settled outcome.

This is too weak for reliable replay. A user watching the replay will see many
tap markers that never get a corresponding visual or semantic outcome.

### 2. Some settled taps still lack destination frames

Among the 23 `tap_settled` events:

| Settled result | Rows | Missing after frame |
| --- | ---: | ---: |
| `navigated` | 9 | 0 |
| `changed` | 8 | 0 |
| `unknown` | 6 | 6 |

The `unknown` settled events are explicit failures for replay quality. They are
bounded, which is better than silently borrowing stale frames, but the user
experience is still degraded.

### 3. Missing-frame coordinate fallback still happened

One raw tap emitted:

- `captureCoordinate.unavailableReason = missing_frame`
- `captureCoordinate.sourceSpace = globalLogical`
- zero frame width/height in the coordinate payload

This is the exact class of evidence that can produce tap markers that appear to
point at nowhere or use fallback geometry.

### 4. The SDK appears to over-record repeated taps

Two bursts are suspicious:

| Timestamp second | Tap rows | Distinct positions |
| --- | ---: | ---: |
| `2026-07-27 08:57:45 UTC` | 16 | 1 |
| `2026-07-27 08:57:52 UTC` | 38 | 1 |

Both bursts recorded many taps at effectively the same position within one
second. This looks like repeated pointer/tap emission for one physical
interaction or a gesture sequence that should be coalesced before replay.

This likely explains a major part of the replay feeling erratic: the player may
be faithfully rendering an event stream that is already too noisy.

### 5. Atlas context build identity was missing for diagnostics

All 37 `capture_diagnostic` events had
`contextEnrichment.reason = missing_context_graph_build_identity`.

This does not invalidate SDK capture evidence, but it means the diagnostics were
not enriched against a resolved graph build. For acceptance, replay visual
coherence must still be judged separately from graph enrichment.

## Route and modal evidence

Observed route changes:

| Route | Navigation | Rows | Frames |
| --- | --- | ---: | --- |
| `/home` | `route_push` | 1 | `frame-7` |
| `/subscriptionPaywall` | `route_push` | 2 | `frame-19`, `frame-271` |
| `/home` | `route_pop` | 1 | `frame-28` |
| `/stageit/recents` | `route_push` | 1 | `frame-173` |
| `/aiStudio/upload` | `route_replace` | 1 | `frame-186` |
| `ModalBottomSheetRoute<StageItGenInputBottomsheetValue>` | `route_push` | 2 | `frame-196`, `frame-231` |
| `/stageit/results` | `route_pop` | 3 | `frame-202`, `frame-223`, `frame-322` |
| `/imageChooser` | `route_push` | 1 | `frame-210` |
| `/usageStatsError` | `route_push` | 1 | `frame-260` |
| `/stageit/image` | `route_push` | 1 | `frame-328` |
| `aiStudio/videos/anyImage` | `route_push` | 1 | `frame-336` |
| `/stageit/image` | `route_pop` | 1 | `frame-348` |

Bottom sheets and paywalls were therefore not completely invisible to the SDK in
this run. The remaining issue is not route observation itself; it is the
quality and completeness of the interaction evidence around those routes.

## Recommended follow-up issues

1. Deduplicate repeated raw tap events before they reach replay.
2. Raise `tap_settled` coverage and explicitly classify taps that will not
   settle.
3. Prevent `missing_frame` coordinate fallback from producing zero-size replay
   coordinates without a clear degraded visual state.
4. Add a focused runtime acceptance flow for bottom sheets and paywalls in the
   Blend app, using production collection and dashboard replay inspection.
5. Ensure capture diagnostics include or can resolve Atlas context build
   identity, so replay-quality diagnostics and enrichment state can be separated
   cleanly.

## Acceptance status

Rejected for production replay acceptance.

Reason: although SDK `0.4.12` improved frame provenance, route capture, modal
capture, and diagnostic visibility, this session still contains too many
unsettled taps, repeated tap bursts, and a missing-frame coordinate fallback to
call the replay coherent.
