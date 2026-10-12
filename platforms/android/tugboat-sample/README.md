# tugboat-sample

Sample app for the native Android SDK (`:tugboat-android`), for device tests
on an emulator against a local collector (native SDK note section 10). Not
published. Application id `com.tugboat.sample`, minSdk 24 (frames need API
26+; below that sessions carry events without frames).

Screens:

- `MainActivity` (Views): a tagged button (`tugboatTag = "primary_action"`),
  a swipe area, a text field, a `RecyclerView` list of 50 rows, a dialog,
  buttons to the other screens, and a **Stop Tugboat** button.
- `DetailActivity` (Views): text, an image, a tagged back button.
- `ComposeWholeHostActivity` (Compose, default `ComposeMasking.WholeHost`):
  a tagged button (`Modifier.tugboatTag("compose_primary")`), a text field,
  and a `LazyColumn`. Every frame masks the whole Compose host.
- `ComposeSemanticsActivity` (Compose, opted into
  `ComposeMasking.SemanticsBestEffort` while resumed): a text field and a
  `LazyColumn` of clickable rows (Navigation Compose destination `rows`); a
  row opens `row/{index}` (route key `row`), with text, a described image,
  and a tagged back button (`compose_back`). It draws nothing without
  semantics (no undescribed images, no `Canvas` text), so semantics masks
  cover everything private.

`SampleApplication` starts Tugboat with focus and system-input capture on,
installs the Compose adapter (`TugboatCompose.install(composeMasking =
ComposeMasking.WholeHost)`), and sets traits `{sample: true}`. Masking is
process-wide, so `ComposeSemanticsActivity` installs `SemanticsBestEffort`
in `onResume` and restores `WholeHost` in `onPause`.
`Tugboat.trackNavigation(navController)` feeds its destinations to the Views
adapter's route keys.

## Build, install, run

From `platforms/android` (Android SDK, NDK `28.2.13676358`, CMake `3.22.1`;
the debug build compiles the session engine and the image core):

```sh
./gradlew :tugboat-sample:installDebug \
  -Ptugboat.collectorUrl=http://10.0.2.2:3000 \
  -Ptugboat.collectorKey=pmk_blend-app-dev-secret
adb shell am start -n com.tugboat.sample/.MainActivity
adb logcat -s Tugboat TugboatEngine TugboatHttp TugboatCapture TugboatViews TugboatStop
```

- `tugboat.collectorUrl` / `tugboat.collectorKey` are Gradle properties
  compiled into `BuildConfig`. The defaults are `http://10.0.2.2:3000` (the
  emulator's route to the host's port 3000) and `pmk_blend-app-dev-secret`,
  so a plain `./gradlew :tugboat-sample:installDebug` works against the
  local pmkit collector.
- Debug builds allow cleartext HTTP to `10.0.2.2` and `localhost` only
  (`src/debug/res/xml/network_security_config.xml`); release builds allow
  none.
- On a physical device, `adb reverse tcp:3000 tcp:3000` and
  `-Ptugboat.collectorUrl=http://localhost:3000`.
- `Tugboat not started: required session_start fields are missing: […]` in
  logcat means the start was refused; nothing is sent.

## Device-test script

Fresh install, collector running, logcat open:

1. **Launch** the app. Wait 2 s.
2. **Tap** "Tap me" once (the counter shows 1).
3. **Scroll** the list: one fling up, wait for it to stop.
4. **Swipe** left across the green "Swipe here" area.
5. **Open the second screen**: tap "Open details". Wait 2 s, then press
   the system back key (`adb shell input keyevent KEYCODE_BACK`).
6. **Type** in the text field: tap it, type `hello`, press back to hide the
   keyboard.
7. **Rotate** to landscape, wait 2 s, rotate back to portrait, wait 2 s
   (`adb shell settings put system accelerometer_rotation 0`, then
   `adb shell settings put system user_rotation 1` and `… 0`).
8. **Background**: press Home, wait 3 s.
9. **Foreground**: reopen the app from recents, wait 2 s.
10. **Compose, whole host**: tap "Compose". Tap "Tapped 0 times", fling the
    list, tap the text field and type `abc`, press back twice (keyboard,
    then screen). Wait 2 s.
11. **Compose, semantics**: tap "Compose (semantics)". Fling the list, tap
    "Row 3" (opens `row/3`), wait 2 s, tap "Back", then press the system back
    key. Wait 2 s.
12. **Stop**: tap "Stop Tugboat". Wait 10 s before checking the collector.

## Expected collector rows

Session rows are filed under the app id `com.tugboat.sample` (key
`pmk_blend-app-dev-secret`, collector app `blend_app`). Event `route` names
are the activity class names; inside `ComposeSemanticsActivity` anchors use
the Navigation route keys `rows` and `row` (arguments stripped).

- `pmkit.sessions`: one `session_start` (with `appInfo.version` 0.1.0,
  `buildNumber` 1, the full `device` object, `ipInfo.ip` `10.0.2.2`,
  `locale`, traits) and one `session_end` for the session.
- `pmkit.raw_events`:
  - `route_change` for `com.tugboat.sample.MainActivity` (launch),
    `com.tugboat.sample.DetailActivity` (step 5), `MainActivity` again on
    back, `ComposeWholeHostActivity` (step 10), `ComposeSemanticsActivity`
    (step 11), and `MainActivity` after each; a rotation recreates the
    activity but keeps its route, so it adds no `route_change`. Navigation
    Compose destinations change route keys, not routes: no `route_change`
    for `row/3`;
  - `interaction` events (v2, no `stateAnchor`): a `tap` on the button
    (step 2, `targetAnchor.toolkit = "view"`, tag fingerprint from
    `primary_action`), a `scroll` on the list (step 3), a `swipe` (step 4),
    taps on "Open details" and the text field, all with
    `targetAnchor.toolkit = "view"`;
  - Compose `interaction` events with `targetAnchor.toolkit = "compose"`:
    the tap on the button (step 10, tag fingerprint from
    `compose_primary`), the list `scroll`s (steps 10 and 11, scrollable ids
    `compose-scroll-<n>`), taps on the text fields, on "Row 3" (route key
    `rows`), and on "Back" (route key `row`, tag `compose_back`);
  - `focus_changed` when the text fields gain and lose focus (steps 6, 10,
    11);
  - `system_input` `back` (steps 5, 10, 11 for the presses that reach the
    app; a back press that only hides the keyboard goes to the keyboard);
  - lifecycle: `app_foregrounded` (launch, step 9), `app_inactive` and
    `app_backgrounded` (step 8).
- `pmkit.frame_captures` and S3 `pmkit-frames/<sessionId>/<frameNo>.jpg`:
  frames for the initial capture, each route, interactions, and the
  foreground. Views screens: every text, button, list row, the text field,
  and the image are masked (filled rectangles). `ComposeWholeHostActivity`:
  the whole Compose area is one filled rectangle. `ComposeSemanticsActivity`:
  texts, the text field, and the described image are masked individually;
  button and row backgrounds stay visible. Frames taken mid-transition are
  fully masked. `frameMetadata` backends are `nativeCpuExperimental`.
  Mask coverage (`precise` / `wholeHost` / `wholeFrame`) is not on the wire
  until engine PR #96 merges.
- No 400s in the collector log.

Known gaps: the dialog is a separate window, so it is not in frames and its
taps are not recorded; predictive back is not observed; Compose scroll
offsets are approximate (per-frame samples).
