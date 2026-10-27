# tugboat-sample

Sample app for the native Android SDK (`:tugboat-android`), for device tests
on an emulator against a local collector (native SDK note section 10). Not
published. Application id `com.tugboat.sample`, minSdk 24 (frames need API
26+; below that sessions carry events without frames).

Screens (all edge-to-edge safe: content is padded by the system bars and
display cutout, as targetSdk 35 requires on API 35+):

- `MainActivity` (Views): a tagged button (`tugboatTag = "primary_action"`),
  a swipe area, a text field, a `RecyclerView` list of 50 rows, a framework
  dialog (its taps are not recorded: the documented gap), buttons to the
  other screens, and a **Stop Tugboat** button.
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
- `FragmentsActivity` (Views and Compose fragments, no Jetpack Navigation):
  "Views fragment" and "Compose fragment" replace the fragment in a
  `FragmentContainerView`. The Views fragment (`views_home`) has a clickable
  root, a text, and a tagged button (`fragment_action`); the Compose
  fragment (`compose_home`) is a `ComposeView` with a tagged button
  (`compose_fragment_action`).
- `DialogsActivity` (AppCompat theme, Compose content; for the dialog-window
  device pass): buttons open an AppCompat `AlertDialog`, a `DialogFragment`
  (tag `sample_dialog`, tagged button `dialog_fragment_ok`), a Compose
  `Dialog` with a text field (`compose_dialog_note`, `compose_dialog_ok`),
  and a material3 `ModalBottomSheet` (`bottom_sheet_ok`). Taps, BACK, and
  focus in each are recorded (the `DialogFragment` on every API level, the
  others on API 29+); none is in the frames.

`SampleApplication` starts Tugboat with `enabled = true` (the SDK default is
dormant until `Tugboat.activate`; `-Ptugboat.enabled=false` builds a
dormant sample), focus, system-input capture, and scene inventory on,
installs the Compose adapter
(`TugboatCompose.install(composeMasking = ComposeMasking.WholeHost)`), and
sets traits `{sample: true}`. Masking is process-wide, so
`ComposeSemanticsActivity` installs `SemanticsBestEffort` in `onResume` and
restores `WholeHost` in `onPause`.
`Tugboat.trackNavigation(navController)` makes its destinations route keys
and `route_change`s.
Coded events and network calls: "Tap me" records the coded event
`PRIMARY_TAPPED` through `Tugboat.eventHook(source = "sample",
parameterPolicy = ParameterPolicy.allowList(setOf("taps")))`, and "Open
details" records one manual call, `Tugboat.beginNetworkCall("GET",
"/details/42")`, completed with status 200 after 200 ms (it stands in for a
request), and makes one real request through `SampleHttp`'s OkHttp client:
`GET <collectorUrl>/sample/orders/42?ref=sample` with an `Authorization`
header, recorded by `TugboatOkHttpInterceptor` (added first, outermost;
[`tugboat-okhttp`](../tugboat-okhttp/README.md)) as route
`/sample/orders/{id}`. The collector has no such path and answers 404,
recorded with its bounded error body.

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
   keyboard (on Android this keeps the field focused), then tap "Open
   details" so focus leaves the field. Wait 2 s, then press the system back
   key.
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
12. **Fragments**: tap "Fragments". Tap "Fragment action", tap "Compose
    fragment", tap "Compose fragment action", then press the system back
    key. Wait 2 s.
13. **Stop**: tap "Stop Tugboat". Wait 10 s before checking the collector.

## Activation script (debug builds)

`TugboatDebugReceiver` (debug manifest only) drives the activation lifecycle:

```sh
./gradlew :tugboat-sample:installDebug -Ptugboat.enabled=false
adb shell am start -n com.tugboat.sample/.MainActivity      # dormant: no rows
adb shell am broadcast -n com.tugboat.sample/.TugboatDebugReceiver \
  -a com.tugboat.sample.ACTIVATE --es id run-1               # session_start {activationRequestId: run-1}
adb shell am broadcast -n com.tugboat.sample/.TugboatDebugReceiver \
  -a com.tugboat.sample.DEACTIVATE                           # session_end
```

An `ACTIVATE` while `MainActivity` is resumed records its taps at once (no
new resume needed); an `ACTIVATE` with another id ends the session and
starts one with the new id.

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
    Compose destinations are routes too, on a navigator nested under the
    activity's: `route_change` to `rows` when `ComposeSemanticsActivity`
    opens, to `row` (step 11, `row/3` without its argument), and back to
    `rows` on "Back";
  - `interaction` events (v2, no `stateAnchor`). As in Flutter, only taps
    resolve a target and scrolls carry their scrollable's anchor; swipe,
    pan, and zoom carry **no** `targetAnchor` (so no `toolkit`):
    - `tap` on the button (step 2, `targetAnchor.toolkit = "view"`, tag
      fingerprint from `primary_action`), and taps on "Open details" and the
      text field, all with `targetAnchor.toolkit = "view"`;
    - `scroll` on the list (step 3), `targetAnchor` = the `RecyclerView`,
      `toolkit = "view"`;
    - `swipe` (step 4), without a `targetAnchor`;
    - taps that open an activity carry the route frame as `afterFrame`
      (the route change claims them), except the tap on "Compose
      (semantics)" (step 11): that activity's NavHost reports its start
      destination `rows` as a nested route right after the activity route,
      and a tap whose route is followed by a route it did not cause keeps
      only its `beforeFrame` (engine rule, as in Dart for a page with a
      nested `Navigator`; the `rows` `route_change` carries the frame);
  - Compose `interaction` events with `targetAnchor.toolkit = "compose"`:
    the tap on the button (step 10, tag fingerprint from
    `compose_primary`), taps on the text fields, on "Row 3" (route key
    `rows`), and on "Back" (route key `row`, tag `compose_back`), and the
    list `scroll`s (steps 10 and 11, anchored to the `LazyColumn`);
  - `focus_changed` with `focus: text_input` when a text field is tapped
    (steps 6 and 10). Focus is app-wide, as in Dart: when step 6 opens
    "Open details", the new window's focus is reported (`focus: none` or
    `other`, `previousFocus: text_input`), and coming back reports the
    still-focused field (`text_input`) again. Hiding the keyboard does not
    clear focus on Android, so it records nothing. The Compose screens open
    with nothing focused (no keyboard);
  - `system_input` `back` (steps 5, 10, 11 for the presses that reach the
    app; a back press that only hides the keyboard goes to the keyboard);
  - `external_event` (`stream: evidence`) `PRIMARY_TAPPED` with `source:
    sample`, `parameterKeys` `[taps, screen]`, and only `taps` in
    `parameters` (step 2), and `network_call` `GET /details/42`, `outcome:
    response`, `statusCode: 200`, `durationMs` about 200 (step 5 and step 6),
    and with each a `network_call` `GET /sample/orders/{id}` from the OkHttp
    interceptor, `outcome: response`, `statusCode: 404` (the local pmkit
    collector's answer for an unknown path), `errorResponseBody` `404 Not
    Found` with `errorResponseBodyCapture.format: text`, and no query,
    header, or host anywhere in the event;
  - lifecycle: `app_foregrounded` (launch, step 9), `app_inactive` and
    `app_backgrounded` (step 8). Two events can share an `atMs` (millisecond
    resolution, as in Dart); their order is the session's event order
    (`event-N`, minted in append order), not `atMs`;
  - `scene_inventory` (`emitSceneInventory`): one per route and inventory
    hash, after captured frames, under the route of the visible content.
    In step 12 they are `views_home` (with an element whose `canonicalPath`
    is `""`: the fragment's clickable root) and `compose_home`, not the
    activity class; each tapped `targetAnchor.fingerprint` is an element
    `fingerprint` (or alias) of the preceding inventory for its route,
    except taps on activity-level chrome outside the shown fragment (here the
    "Views fragment" / "Compose fragment" buttons), which have no inventory;
  - the "Stop Tugboat" tap (step 13) as `interaction` `gesture: cancelled`
    with a `beforeFrame` and no `afterFrame`, just before `session_end`: the
    session ends while the tap is still settling, and ending a session
    abandons pending taps as `cancelled` (Dart parity).
- `pmkit.frame_captures` and S3 `pmkit-frames/<sessionId>/<frameNo>.jpg`:
  frames for the initial capture, each route, interactions, and the
  foreground. Views screens: every text, button, list row, the text field,
  and the image are masked (filled rectangles). `ComposeWholeHostActivity`:
  the whole Compose area is one filled rectangle. `ComposeSemanticsActivity`:
  texts, the text field, and the described image are masked individually;
  button and row backgrounds stay visible. Frames taken mid-transition are
  fully masked. `frameMetadata` backends are `androidPixelCopy`.
  Each captured frame's mask coverage is a `capture_diagnostic` row in
  `pmkit.raw_events` with `component: capture_masking`, the `frameId`,
  `mode` (`precise` on Views screens and `ComposeSemanticsActivity`,
  `wholeHost` with `composeDefault` on `ComposeWholeHostActivity`,
  `wholeFrame` with `animating` mid-transition), and `reasons`.
  `frameMetadata` does not change.
  Frame sizes can step down mid-session (for example 309×686 to 247×549):
  when captures exceed the screenshot budget (60 ms per 5 s, Dart parity),
  later captures use `degradedScale` 0.8 until the window recovers. Expected
  on slow emulators.
- No 400s in the collector log for SDK uploads. The sample's own `GET /sample/orders/42` (steps 5 and 6) is answered 404, as expected.

Known gaps: dialogs are separate windows, so they are not in frames (frames
taken while one is up carry `overlayWindow`); the framework dialog on
`MainActivity` has no recorded taps, and below API 29 only the
`DialogFragment` does; predictive back is not observed; Compose scroll
offsets are approximate (per-frame samples).
