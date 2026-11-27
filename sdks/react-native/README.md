# React Native adapter

`@tugboat/react-native` 0.0.6: Android and iOS, unpublished. A thin TurboModule over
`tugboat-android` and the Swift host (`platforms/apple`). React Native draws real
native views, so the host's adapter records frames, masks, taps and scrolls as in
a native app. JavaScript starts the SDK and marks sensitive regions; events are
built by the shared C++ engine, never in JavaScript. Raw pixels never enter
JavaScript. Plan: `internal/docs/plans/2026-11-27-react-native-sdk-0.0.1-plan.md`.

```ts
Tugboat.start({
  collector: { baseUrl, apiKey },
  app: { name },
  enabled: true, // default false: dormant until Tugboat.activate(id)
});
<Tugboat.Sensitive>{/* card fields, ... */}</Tugboat.Sensitive>
```

Also `activate`, `deactivate`, `stop`, `setUserId`, `setTraits`. `fetch` and
`XMLHttpRequest` are recorded through an OkHttp interceptor (path only), which
replaces an app's own `NetworkingModule.setCustomClientBuilder`.

## iOS: the Swift host as local pods

The module (`ios/`) calls the Swift host through `TugboatRN.swift`. The host is
unpublished, so the app's Podfile lists it as local pods from the repository root
(`example/ios/Podfile` does this; the three have no other source yet):

```ruby
pod 'TugboatSessionEngine', :path => '<repo>'   # core/session-engine (C++)
pod 'TugboatCaptureRuntime', :path => '<repo>'  # masked screenshots
pod 'Tugboat', :path => '<repo>'                # platforms/apple/Sources/Tugboat
```

Local pods rather than SwiftPM: React Native's CocoaPods integration can only add
a SwiftPM package by URL and version (`spm_dependency`), and a local path cannot
be a dependency of an autolinked pod. `Tugboat.podspec` and
`TugboatSessionEngine.podspec` list the same sources as the targets in
`Package.swift`. The engine is built as C++17 (`-std=c++17`): React Native sets
C++20 on every pod, which its JSON types do not compile under.

Then `cd example/ios && pod install`, and build `RnExample.xcworkspace`.

How iOS differs from Android:
- JavaScript names every screen (`setScreen`, `trackNavigation`); no view
  controller is a route (`trackHostingControllers: false`). The first screen named
  is the session's initial route (`session_start`, with a frame of its own, as on
  Android), and an app that never names one reports no routes.
- A `testID` is the view's `accessibilityIdentifier`. The host treats a view with
  one as a tap target and a `Named#<ordinal>` path segment (the name never enters
  the path), and the name is the anchor's `tag`, so `tagFingerprint` is the alias.
  Android puts the `testID` in the path as `ViewGroup#<testID>`, so fingerprints
  differ between platforms.
- React Native's paragraph and image views draw their own pixels and are masked
  whole (the host's `setViewRoleClassifier`); `UITextField`/`UITextView` inside
  text inputs are masked as in any app. `<Tugboat.Sensitive>` masks its view and
  everything under it.
- Network: `TugboatHTTPRequestHandler` replaces React Native's HTTP handler while
  `captureNetwork` is on (after `Tugboat.start`), with the same session setup (no
  custom session configuration or interceptor, which RN lets an app set through
  `RCTSetCustomNSURLSessionConfigurationProvider`). `captureNetwork: false` leaves
  the default handler alone. Route is the URL path, percent-encoded, never the
  query.
- Tap targets: only a view with a `testID` is a target (Android targets any
  clickable view), so a `Pressable` without one resolves to its nearest named
  ancestor. A named target's anchor carries `actions: ["tap"]` and `enabled` (the
  view takes touches and is not marked not-enabled); iOS cannot tell a `Pressable` from a plain view, so every named view
  reports `tap`. `<Text
  testID>` and a `testID` on a `TextInput` or scroll view are not used as the tag.
  `captureSystemInput` is ignored on iOS. `accessibilityIdentifier` values are sent
  as the tag (as Android sends `testID`): data-derived ids are sent too.
- Network: remote `<Image>` downloads also go through React Native's networking
  but are not recorded (as on Android and in Flutter): the handler skips requests
  React Native's image loader tags (`trackingName` `RCTImageLoader`). A `fetch` or
  `XMLHttpRequest` of an image URL is still recorded. The handler also bypasses anything that wraps
  `RCTHTTPRequestHandler` (certificate pinning by category or swizzle), and copies
  RN 0.88's handler, so check it on an RN upgrade. It handles requests from `start`
  on, also while Tugboat is dormant.
- There is no early install as on Android: the host adopts the key window that
  already exists when `Tugboat.start` runs, so frames begin at `start`.

## Android: build against the in-repo SDK

The Android library depends on `tugboat-android` and `tugboat-okhttp` from the
git-ignored `.local-maven`. Publish them first (needs the NDK in `AGENTS.md`):

```sh
cd platforms/android && ./gradlew :capture-runtime:publishAllPublicationsToLocalCaptureRepository \
  :tugboat-android:publishAllPublicationsToLocalCaptureRepository \
  :tugboat-okhttp:publishAllPublicationsToLocalCaptureRepository
```

Then build `example/` (see its README). Known gaps in 0.0.6 (Android unless noted):
- Screens: `Tugboat.trackNavigation(navigationRef)` (React Navigation) or
  `Tugboat.setScreen(name, instanceId?)`. A `testID` is the view's tag and
  fingerprint name. A content provider installs the observation before the first
  activity, so `Tugboat.start` may run late.
- Not yet handled: the screen name is lost when the activity is recreated; a
  `setScreen` while the activity is paused is dropped; a reused instance id with
  a new name keeps the old name; a late `start` skips launch correlation until the next
  resume.
- Network: a call whose URL path has percent-encoded characters (spaces,
  non-ASCII) is not recorded. `captureNetwork: false` leaves an app's own
  `setCustomClientBuilder` alone; the default replaces it.
- `<Tugboat.Sensitive>` is a real view on Android and iOS; on other platforms it
  renders its children only (no wrapper view, `style` ignored).
- If the native module is not linked, calls warn once ("the native module is not
  linked") and `<Tugboat.Sensitive>` fails to render.
