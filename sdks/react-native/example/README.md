# Tugboat React Native sample app

A shop-flow sample that mirrors `sdks/flutter/packages/tugboat/example`, used to
test the upcoming `@tugboat-ai/react-native` SDK. React Native 0.88 (New
Architecture, Hermes), TypeScript, React Navigation. Android and iOS.

Package and bundle id: `com.tugboat.rnexample`.

## Screens

Home, Catalog (tabs, search, category chips, list/grid), Browse feed, Cart,
Shipping (form inputs), Payment (card fields wrapped in `Sensitive`), Profile
(settings, human-verification dialog), Scroll playground (vertical list,
horizontal carousel, static block, nested scroll), and Network (fetch and
XMLHttpRequest: GET, POST, 404, 500, failing host, against a configurable base
URL, default `https://httpbin.org`). Every interactive element has a `testID`.

## Where the SDK plugs in

`src/tugboat.ts` starts `@tugboat-ai/react-native` (`file:..`) against the local
capture collector (`http://localhost:3000`, via `adb reverse tcp:3000 tcp:3000`)
and exports `Sensitive`. The Payment card fields and the profile one-time-code
field are wrapped in it. Publish the Android SDK to `.local-maven` first: see
`../README.md`. Release builds allow cleartext only to `localhost`; debug builds
also allow `10.0.2.2` (emulator host).

## Run

```sh
cd sdks/react-native/example
npm install
npm start                 # Metro, in one terminal
npm run android           # debug build to a device or emulator
```

## Run on iOS

`ios/Podfile` adds the in-repo Swift host as local pods (see `../README.md`).

```sh
cd sdks/react-native/example/ios && pod install
cd .. && npm run ios      # simulator; JS from Metro
```

The collector is `http://localhost:3000` (the simulator shares the Mac's network).
For a phone, point `baseUrl` in `src/tugboat.ts` at the Mac's LAN address and start
the collector with `--host 0.0.0.0`; a Release build embeds the JS bundle.
`RnExampleUITests` is a small XCUITest that drives the shop flow (cold launch to
the Network screen, plus a second launch of seven taps), used for device runs:

```sh
xcodebuild test -workspace RnExample.xcworkspace -scheme RnExample -configuration Release \
  -destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<team> TUGBOAT_BUNDLE_SUFFIX=.<unique> \
  -only-testing:RnExampleUITests/RnExampleUITests/testFullFlow
```

`RnExampleTests` is a unit-test bundle hosted in the app (the iOS HTTP handler's
image-request filter); run it on a simulator:

```sh
xcodebuild test -workspace RnExample.xcworkspace -scheme RnExample \
  -destination 'platform=iOS Simulator,name=<simulator>' -only-testing:RnExampleTests
```

## Build APKs

```sh
cd sdks/react-native/example/android
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties   # once
./gradlew assembleDebug assembleRelease
```

A plain debug APK loads JS from Metro. To make one that runs without Metro
(device checks, CI), embed the bundle:

```sh
./gradlew assembleDebug -PbundleDebug
```

Outputs: `android/app/build/outputs/apk/{debug,release}/`. The release build is
signed with the template debug keystore: fine for testing, not for publishing.

## Network screen against a local server

On an Android emulator the host machine is `http://10.0.2.2:<port>`; on a phone
use `adb reverse tcp:<port> tcp:<port>` and `http://localhost:<port>`. Edit the
base URL field on the Network screen. The failing-host requests ignore it.
