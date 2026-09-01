# Production replay acceptance: interaction consolidation (0.4.15)

Use this after shipping SDK **0.4.15** (canonical interactions + delayed
reconciliation) and running Blend through the acceptance flow.

## Baseline (locked)

Prefer the nearest prior Blend session against SDK **0.4.12 / 0.4.13** for
side-by-side scoring. Record the new session id and Blend build before scoring.

## What changed in the SDK

| Concern | 0.4.13 behavior | 0.4.15 behavior |
| --- | --- | --- |
| Gesture identity | `tap` + `tap_settled` peers | one `interaction` (`stream: semantic`) + legacy projection |
| Claim window | microtask same-turn only | default 1,250 ms delayed reconciliation |
| Diagnostics | mixed into normal events | `stream: diagnostic` |
| Origin | frozen on pending tap | immutable `InteractionOrigin` on the transaction |
| Swipe state | refreshed at pointer-up | frozen to pointer-down origin |

## Manual run checklist

1. Point Blend at tugboat **0.4.15**.
2. Drive: home scroll/flick, Get Pro / paywall, full-screen navigation, modal
   bottom sheet, asynchronous onboarding transition, rapid double-tap,
   automatic redirect after a settled tap.
3. Paste the new `sessionId` (+ Blend build) for scoring.

## Hard gates (all must PASS)

1. **Identity** — `metadata.sdkVersion = '0.4.15'`.
2. **Canonical coverage** — one `stream: semantic` `interaction` per completed
   user gesture (tap / swipe / scroll / cancelled).
3. **Origin correctness** — interaction `origin.route` / `origin.targetAnchor`
   match the pointer-down screen/component, never the destination.
4. **Delayed attribution** — delayed navigation / bottom sheet inside 1,250 ms
   has `attribution.kind = delayed_likely` (or `direct`) and
   `result.status = navigated|changed`, with matching
   `route_change.causedByInteractionId`.
5. **Automatic false-claim rate** — timer/auth redirects after the window, and
   routes with competing pointers, stay `navigationOrigin =
   automatic_or_unknown`.
6. **No inferred tap for scrolls/swipes** — completed scroll/swipe produces no
   `stream: semantic` tap; one `interaction` with `gesture=scroll|swipe`.
7. **Diagnostic isolation** — enrichment selection of inferred events (`stream: semantic`
   excludes `capture_diagnostic`.
8. **Rage-tap precision** — three no-result taps on the same origin target flag
   once; three scrolls or three successful navigation taps do not.

## Soft / observational

- Inferred event count per completed gesture should drop vs 0.4.0 raw
  `tap`+`tap_settled`+scroll peer inflation.
- Legacy projection remains present until collector/graph cut over; do not
  delete `tap`/`tap_settled` selection until two representative Blend flows pass
  on canonical interactions alone.
- Instrument pending-to-success latency; retune `interactionClaimWindow` from
  production evidence if 1,250 ms is too short/long.

## Consumer follow-ups (separate PRs)

- Collector / Context Graph enrichment select `stream: semantic` `interaction`
  and map components via `origin.targetAnchor`.
- Build causal edges from `result` / `causedByInteractionId`.
- Update dashboard rage-tap detectors to the definition above.
