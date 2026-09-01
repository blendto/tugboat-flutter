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
| Host app | Blend Android (local path override, not a published pairing) |
| Flutter | FVM `3.35.7` |
| Device | Android API 35 emulator, 1080 × 2400 |
| Collector | local exploration |

Launch used local `tugboat` / `tugboat_dio` path overrides and a local
collector. Host-app paths, package ids, session ids, and run ids are omitted
from this tree.

The operator sent each touch sequence through authenticated Android Emulator
gRPC `sendTouch`. PMKit did not drive the app. Each input used continuous touch
contacts with explicit release events. The operator checked the screen between
actions and saved before/after screenshots.

The tested path was Home → Create design → Start Blank → Done → Add → Gallery
sample → Use Original. The sample was Blend's bundled onboarding asset. No
private photo was used. All six gesture tests ran on `/canvas` with that photo
selected.

An earlier onboarding/photo flow stalled at a purchase-page loading screen.
The operator restarted the app without clearing data. No purchase was made.

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

The raw run and PNG evidence stay on the operator machine. They are not stored
in this repository.

The recording finished with `q`. Strict inspect passed with exit code 0. The
inspector reports `ok`, 11 steps, 62 step SDK events, and 75 background
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
