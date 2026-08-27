# Blend gesture check — 2026-08-26

## Verdict

The local SDK records two-finger zoom in, zoom out, and pan in the real Blend
Android app. The photo changes size or position in these tests. A one-finger
photo drag records `swipe`, which is the intended classification. The Android
recorder labels, splits, or omits host steps incorrectly for some multi-touch
inputs.

Product decision, 2026-08-27: keep one-finger pan classified as `swipe`.
This is not a defect and does not require a separate pan classification.

`interaction` is the expected event type. The gesture is in `data.gesture`.
This check used the local fixes, not the released SDK alone.

## Build and method

| Item | Value |
| --- | --- |
| SDK | `0.8.8` plus the local, unreleased gesture fixes |
| SDK base commit | `8b5442aa0c43e701548f7e5a9ba3c46d37ef68bd` |
| Blend | `to.blend.mobile_app`, `3.17.183 (1478)` |
| Blend commit | `4cb7172499c8c74fe80914c5f755b60b7a99142a` |
| Flutter | FVM `3.35.7` |
| PMKit CLI commit | `c3c332d5d89e2d34857ecc3b7487c40fe575e3f9` |
| Device | `emulator-5554`, `device_api35_tugboat`, Android API 35 |
| Input screen | 1080 × 2400 physical pixels |
| Run | `e55d7487-16d3-4e7c-b429-fd7f501c9393` |
| SDK session | `session-1787735905652208` |
| Run UTC range | `2026-08-26T09:19:55.815Z` to `2026-08-26T10:12:00.180Z` |

Blend used the existing local `tugboat` and `tugboat_dio` path overrides.
Launch command, from `/Users/chinukb/work/mobile_app`:

```sh
fvm flutter run -d emulator-5554 --dart-define=TUGBOAT_EXPLORATION=1 --dart-define=TUGBOAT_COLLECTOR_ENV=local
```

The PMKit CLI recorded passively:

```sh
bun src/cli.ts record --device emulator-5554 --package to.blend.mobile_app --settle 1200
```

The operator sent each touch sequence through authenticated Android Emulator
gRPC `sendTouch`. PMKit did not drive the app. Each input used continuous touch
contacts with explicit release events. The operator checked the screen between
actions and saved before/after screenshots.

The tested path was Home → Create design → Start Blank → Done → Add → Gallery
sample → Use Original. The sample was Blend's bundled
`assets/images/onboarding/stage_it_onboarding_before.jpg`. No private photo was
used. All six gesture tests ran on `/canvas` with that photo selected.

An earlier onboarding/photo flow stalled at a purchase-page loading screen.
The operator restarted the app without clearing data. No purchase was made.
That setup run is `b2d93716-9b63-4a5a-b1cf-78b5da39a96a`.

## Observed results

| Input | Visible result | SDK event | Recorder host result |
| --- | --- | --- | --- |
| Fingers move apart | Photo grows | `event-130`: `zoom_in`, scale `2.4284`, two pointers | `evt_000006`: `swipe` |
| Fingers move together | Photo shrinks | `event-141`: `zoom_out`, scale `0.4122`, two pointers | No host step; timeline marks it `autonomous` |
| Two fingers move together | Photo moves down and right | `event-150`: `pan`, two pointers | `evt_000007`: `swipe` |
| One finger drags the photo | Photo moves down and right | `event-159`: `swipe` (expected) | `evt_000008`: `swipe` (expected) |
| Pan, lift the primary finger, add a replacement, continue | Photo moves and rotates | One `event-168`: `pan`; no extra SDK swipe | Two host steps: `evt_000009` (`swipe`) and `evt_000010` (`long_press`) |
| Pinch starts 20 physical pixels apart | No visible resize observed | `event-181`: `zoom_in`, scale `3.9984` | `evt_000011`: `long_press`; SDK event remains outside its saved step event list |

The close-start test proves that the SDK classifies the input. It does not
prove that Blend accepted a resize. The replacement-finger test proves SDK
event grouping. Its visible rotation is not evidence of a pure translation.

The first zoom lacks an SDK `beforeFrame` and position fields. It has
`afterFrame: frame-136`. The prior image-insertion interaction also lacks an
after-frame. Independent emulator screenshots preserve the visible before
state for this test. Do not call this complete SDK frame coverage.

The zoom-out frames are `frame-136` → `frame-146`. The two-finger pan frames
are `frame-146` → `frame-155`. The operator opened the SDK after-frame images
for those two tests and confirmed the smaller and moved photo.

## Evidence and quality check

The raw run is local:

```text
/Users/chinukb/work/tugboat/pmkit_cli/.pmkit/runs/e55d7487-16d3-4e7c-b429-fd7f501c9393
```

The separate evidence directory contains 12 before/after PNGs, the six input
sequences, input timestamps, extracted raw SDK events, host actions, build
identity, and the exact SDK source/test diff used by this build:

```text
/Users/chinukb/work/tugboat/pmkit_cli/.pmkit/gesture-verifications/e55d7487-16d3-4e7c-b429-fd7f501c9393
```

The recording finished with `q`. This command passed with exit code 0:

```sh
bun src/cli.ts inspect e55d7487-16d3-4e7c-b429-fd7f501c9393 --write --json --strict
```

The inspector reports `ok`, 11 steps, 62 step SDK events, and 75 background
events. It reports one informational event-gap notice. This is a structural
check. It does not detect the gesture label and step-grouping errors above.
All six gesture after-frame files exist. No run was uploaded.

## Remaining work

The recorder's `src/touch-gesture.ts` only returns `tap`, `long_press`, or
`swipe`. Its `src/touch-monitor.ts` tracks one active touch and does not track
multi-touch slots. These limits explain why the host labels cannot describe
pinch and pan. The SDK timeline retains the gesture facts.

Recommended follow-up:

| Change | Benefit | Risk | Cost | Fastest useful test |
| --- | --- | --- | --- | --- |
| Use the correlated SDK gesture for the semantic step label. Preserve raw host input. Keep a host touch session open until all contacts lift. | Correct labels and one step per gesture | Incorrect joins if SDK and host timing disagree | Medium; CLI parser, grouping, and tests | Repeat these six inputs; check one SDK gesture per intended input and correct host grouping |

Keep one-finger canvas pan as `swipe`. Observed Flutter scrolling remains
`scroll`. No widget-based one-finger pan classification is planned.

Rotation, physical Android devices, iOS, trackpads, production ingestion, and
the production replay UI were not validated in this run. This is not a release
or production acceptance record.
