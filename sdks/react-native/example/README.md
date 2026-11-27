# Tugboat React Native sample app

A shop-flow sample that mirrors `sdks/flutter/packages/tugboat/example`, used to
test the upcoming `@tugboat/react-native` SDK. React Native 0.88 (New
Architecture, Hermes), TypeScript, React Navigation. Android first; `ios/` is
the unmodified community template.

Package: `com.tugboat.rnexample`.

## Screens

Home, Catalog (tabs, search, category chips, list/grid), Browse feed, Cart,
Shipping (form inputs), Payment (card fields wrapped in `Sensitive`), Profile
(settings, human-verification dialog), Scroll playground (vertical list,
horizontal carousel, static block, nested scroll), and Network (fetch and
XMLHttpRequest: GET, POST, 404, 500, failing host, against a configurable base
URL, default `https://httpbin.org`). Every interactive element has a `testID`.

## Where the SDK plugs in

`src/tugboat.ts` starts `@tugboat/react-native` (`file:..`) against the local
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
