# Gesture patch review — 2026-08-27

## Review result

[PR #44](https://github.com/blendto/tugboat-flutter/pull/44) remains open.
Cursor CLI returned `READY_TO_MERGE` after two review rounds.
The reviewed code commit is `58c977c0e3461b3ced3cf153f12f6fec8251a307`.
The base is `da3025cc1108d4738196961952f76128a11e43d1`.

The CLI used its default model, Cursor Grok 4.6 High, in read-only `ask` mode.
It read the source, tests, exact patches, and test logs supplied by the operator.
It did not execute tests or inspect the emulator itself. Its session ID is
`2e0abe2f-a937-4bb1-97ab-c54fbee57644`.

## Findings and fixes

| Finding | Change | Check |
| --- | --- | --- |
| Gesture travel stops when the original primary finger lifts. This was the merge blocker. | Keep primary travel while that contact is down. Then add active-centroid travel from its last endpoint. Contact joins and lifts do not add jumps. | Pan and pinch replacement tests include movement after the primary lifts and movement on the final up. |
| A pause without pointer cancellation can leave stale contacts after resume. | Reset capture contacts on paused, hidden, and detached states. Reset Listener capture on disposal too. | Real wrapper tests cover paused and hidden states, in both global and Listener modes, without `PointerCancel`. The next one-finger drag records `swipe`. |
| The README omits the stationary third-finger fix and does not explain scale. | Document the third-finger behavior and the contact-span scale contract. | Cursor checked the updated README and changelog. |

Cursor found no remaining merge blocker in round two. It left two optional
notes: pointer-ID reuse could cause a travel jump, and
`primaryPointerEndPosition()` has no production caller. These were not changed
in this review round. The helper still has a unit-test caller.

One-finger canvas pan remains `swipe`. The event and fingerprint schemas do
not change. Both packages remain at patch version `0.8.9`.

## Tests

The operator ran these checks with Flutter 3.44.8 and Dart 3.12.2:

- All 37 gesture tests passed.
- All 98 focused SDK tests passed, including app lifecycle coverage.
- The analyzer, formatting, and whitespace checks passed.
- All 19 Dio adapter tests passed before the review fixes. Those fixes do not
  change the adapter.
- The full SDK suite finished with 352 passes and 10 failures.

All 10 failing tests have baseline evidence on `main` at `da3025c`. The earlier
full baseline run reproduced nine failures. The additional test,
`completed interaction bypasses reuse gates with an unchanged compatible frame`,
failed on both the review head and a fresh isolated baseline worktree with the
same content-hash assertion. The suite is not green. These results do not prove
that all screenshot behavior is correct.

Local review artifacts are in `/tmp/tugboat-cursor-review-44/`. They include
both Cursor result files, exact patches, regression logs, focused tests, the
full suite, and `baseline-frame-test.log`. Temporary files are not durable CI
artifacts.

## Acceptance boundary

The operator built and installed the reviewed `0.8.9` code in Blend
`3.17.183 (1478)` with FVM Flutter 3.35.7 on Android API 35. Blend connected to
the passive recorder. The editor could not be reached: closing the paywall
left a loading screen, and a hot restart returned to the paywall after Home.
No app data was cleared and no purchase was made. This attempt did not test
pinch, pan, or the new primary-lift behavior on the device.

Run `e56d549a-d5ad-43ff-9142-7adbba6fe4ac` was saved with `q`. It contains two
tap steps with before/after screenshots, 18 step SDK events, and 100 background
events. Strict inspection returned exit code 1 with `INVENTORY_JOIN_MISS` for
the paywall tap. Counts reconcile, but this is not a passing acceptance run.
The run was not uploaded. The Flutter runner was detached.

Cursor approval is a code-review result. It is not production acceptance.
The earlier [Blend gesture report](blend-gesture-check-2026-08-26.md) used
`0.8.8` plus the original patch. It does not validate the later travel and
lifecycle changes. PMKit host gesture-label and grouping defects remain
outside this SDK PR.

No merge, tag, package publication, upload, or deployment was performed.
