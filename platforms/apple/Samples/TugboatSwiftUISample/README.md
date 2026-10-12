# Tugboat SwiftUI sample

A SwiftUI app (iOS 15+) that runs the native `Tugboat` SDK from this
repository through a local SwiftPM path (the root `Package.swift`). It is the
device-test target of native SDK note section 10. Nothing is published.

| Screen | Route (`.tugboatScreen`) | Content |
| --- | --- | --- |
| Home | `Home` | "Add to cart" button (`.tugboatTag("add-to-cart")`), a swipe card (`swipe-area`), "Open details" link (`open-details`), "Stop Tugboat" button (`stop-tugboat`), a `List` of 60 rows with SF Symbols |
| Details | `Details` | a `TextField` (`note-field`) and a `ScrollView` of 30 text cards |

Navigation uses `NavigationStack` on iOS 16+ and a stack `NavigationView` on
iOS 15. Hosting-controller tracking is off (`trackHostingControllers: false`),
so routes come from `.tugboatScreen` only. Focus changes are on (iOS has no
system input facts yet). `Tugboat.start` runs in
`application(_:didFinishLaunchingWithOptions:)` through an
`@UIApplicationDelegateAdaptor`.

## Collector

The collector URL and key come from launch arguments, read through the
`UserDefaults` argument domain:

| Argument | Default |
| --- | --- |
| `-TugboatCollectorURL <url>` | `http://127.0.0.1:3000` (the local collector, reachable from the simulator) |
| `-TugboatCollectorKey <key>` | `pmk_blend-app-dev-secret` (rows are filed under app id `blend_app`) |

`NSAppTransportSecurity` sets only `NSAllowsLocalNetworking`, so cleartext
HTTP is allowed to loopback and `.local` hosts and nothing else.
`NSLocalNetworkUsageDescription` is set, so on a device pointed at a LAN
collector (`-TugboatCollectorURL http://<mac>.local:3000`) iOS asks for
local-network access once. App fields:
display name `Tugboat Sample`, version `1.0.0` (`MARKETING_VERSION`), build
`1` (`CURRENT_PROJECT_VERSION`), app id `com.gettugboat.sample.swiftui`, and
an installation id kept in user defaults.

## Build and run (Mac, Xcode 15+, XcodeGen)

From the repository root:

```sh
brew install xcodegen                       # once
cd platforms/apple/Samples/TugboatSwiftUISample
xcodegen generate                           # writes TugboatSwiftUISample.xcodeproj (not committed)

xcrun simctl boot "iPhone 17" 2>/dev/null || true   # any iPhone simulator
open -a Simulator

xcodebuild build \
  -project TugboatSwiftUISample.xcodeproj \
  -scheme TugboatSwiftUISample \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO

xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/TugboatSwiftUISample.app
xcrun simctl launch booted com.gettugboat.sample.swiftui \
  -TugboatCollectorURL http://127.0.0.1:3000 \
  -TugboatCollectorKey pmk_blend-app-dev-secret
```

`tool/ci/build-apple-sample.sh` does the generate and build steps on CI.
SDK logs use subsystem `com.gettugboat.sdk`:

```sh
xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == "com.gettugboat.sdk"'
```

To relaunch with a fresh session: `xcrun simctl terminate booted
com.gettugboat.sample.swiftui`, then the `launch` command again.

## Known gaps

- Lifecycle is app-level (`UIApplication` notifications), not per scene.
- No background task: after step 8 the app is suspended, so events still
  pending then are delivered after the foreground in step 9, not before.

## Device-test script

With the local collector running on port 3000:

1. Launch (command above). Wait about 2 s for the initial capture.
2. Tap **Add to cart**.
3. Scroll the list up and down.
4. Swipe left across the orange **Swipe here** card.
5. Tap **Open details**.
6. Tap the text field and type a few characters (for example `hello`),
   then swipe **up** on the cards so the content scrolls (the drag also
   dismisses the keyboard).
7. Rotate to landscape and back: in Simulator, Device > Rotate Left
   (Cmd-Left), scroll the cards once (an interaction captures a landscape
   frame), then Device > Rotate Right (Cmd-Right).
8. Background: `xcrun simctl launch booted com.apple.Preferences` (or Shift-Cmd-H). Wait 2 s.
9. Foreground: `xcrun simctl launch booted com.gettugboat.sample.swiftui`.
10. Go back to Home and tap **Stop Tugboat**. Delivery of the last events and
    `session_end` finishes in the background (at most about 25 s).

## Expected collector rows (ClickHouse `pmkit`)

- `pmkit.sessions`: one `session_start` (with `appInfo.version` `1.0.0`,
  `buildNumber` `1`, `device.platform` `ios`, `screenSize`, densities, `ipInfo.ip`
  `127.0.0.1`, `locale`) and one `session_end` for the session.
- `pmkit.raw_events` for that session:
  - `route_change` for `Home` (session start) and `Details` (step 5), and
    back to `Home` (step 10);
  - `interaction` rows: `tap` on `add-to-cart`, `open-details`, `note-field`
    and `stop-tugboat`; `scroll` for the list (step 3) and the details scroll
    view; `swipe` for the card (step 4, no target anchor). Each
    `targetAnchor` has `toolkit: "swiftui"` (tagged targets carry the tag;
    list rows carry `[item:section.row]`). Untagged targets get their own
    canonical paths (no shared `Representable#0`); a path through a
    fail-closed box is `low` confidence. Interactions carry
    `payload.position`;
  - `focus_changed` when the text field gains and loses focus;
  - `app_inactive`, `app_backgrounded` (step 8), `app_inactive`,
    `app_foregrounded` (step 9);
  - no `stateAnchor` on any v2 interaction.
- `pmkit.frame_captures` and S3 `pmkit-frames/<sessionId>/<frameNo>.jpg`:
  frames with `requestedBackend` / `resolvedBackend` `nativeCpuExperimental`.
  On iOS 26 text and images inside the `NavigationStack` are masked per
  layer (dark `#1a1a1a` boxes over text, images and SF Symbols; the rest of
  the screen is visible) and `capture_masking` says `precise`; on iOS 15–25
  every frame is masked whole (unverified layer allowlist) and says
  `wholeFrame`. Landscape frames after step 7 have the
  rotated size.
- Collector logs: no 400 responses.
