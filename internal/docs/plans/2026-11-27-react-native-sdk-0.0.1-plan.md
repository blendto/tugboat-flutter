# React Native SDK 0.0.1: implementation plan

Status: proposed · 2026-11-27 · Android only, unpublished, tested on one phone with `sdks/react-native/example`.

This is the smallest thing that works. It is not the 0.1.0 design in the
[adapter design note](2026-11-27-react-native-adapter-design-note.md); section 7 lists what it leaves out.

**The decision in one line:** React Native draws real Android Views, so 0.0.1 is a thin
TurboModule over the existing `tugboat-android` SDK. The Views adapter records frames,
masks, taps, scrolls and focus as it does for a native app. JavaScript only starts the
SDK, names the screen and marks sensitive regions. Events are built by the shared C++
engine inside `tugboat-android`, never in JavaScript, so their shape is the native
Android SDK's by construction.

Evidence labels: `file:line` is this repository. **[javap]** is read from the
`react-android-0.88.1` AAR in the local Gradle cache. **[spike]** is section 15 of the
design note. **[unverified]** is not checked.

## 1. Packaging

- `sdks/react-native/package.json`: `@tugboat/react-native` `0.0.1`, `"private": true`,
  `main: src/index.ts` (no build step), peers `react`, `react-native >= 0.88`, optional
  peer `@react-navigation/native`. `codegenConfig` type `all`, Java package
  `com.tugboat.reactnative`.
- **Codegen TurboModule and Fabric component, not a plain module.** A codegen'd Fabric
  component in an autolinked library built and ran on 0.88.1 [spike 15.1]. A legacy
  module would lean on the interop layer, which is [unverified] on 0.88.
- `sdks/react-native/android/build.gradle`: a Kotlin library, minSdk 24, depending on
  `com.gettugboat.sdk:tugboat-android:0.1.0` and `tugboat-okhttp:0.1.0`
  (`tugboat-android/build.gradle.kts:12,26,165-183`, `tugboat-okhttp/build.gradle.kts:9`).
- **Local Maven, not `includeBuild`.** `platforms/android` pins its own Android Gradle
  plugin (`settings.gradle.kts:10-14`), the app uses React Native's, and one build cannot
  load two [unverified, known Gradle limit]. Publish to the git-ignored `.local-maven`
  (`.gitignore:10`), as CI does for `capture-runtime` (`tool/ci/build-android-runtime.sh:23`):
  `./gradlew :capture-runtime:publishAllPublicationsToLocalCaptureRepository :tugboat-android:publishAllPublicationsToLocalCaptureRepository :tugboat-okhttp:publishAllPublicationsToLocalCaptureRepository`.
  The AAR carries the prebuilt engine `.so`, so the app needs no NDK.
- **Sample app:** `"@tugboat/react-native": "file:.."` in its `package.json`, Metro
  `watchFolders` for the parent folder, and
  `maven { url = uri("$rootDir/../../../../.local-maven") }` in the **app's** repositories:
  Gradle resolves `capture-runtime`, a transitive dependency, with the app's repositories.

## 2. Recording and masks

The Views adapter and window capture work unchanged.

| React Native view | Class on 0.88.1 [javap] | Views rule |
| --- | --- | --- |
| `Text` | `ReactTextView` extends `AppCompatTextView` | `is TextView`: text (`WindowMasks.kt:113`) |
| `TextInput` | `ReactEditText` extends `AppCompatEditText` | text, and editable (`ViewRules.kt:36`) |
| `Image` | `ReactImageView` extends Fresco `DraweeView` extends `ImageView` | media (`WindowMasks.kt:114`) |
| `ScrollView`, `FlatList` | `ReactScrollView` extends `ScrollView`; horizontal extends `HorizontalScrollView` | scrollable (`Scrollables.kt:28-30`) |
| `Pressable` | `ReactViewGroup`; `focusable` sets a click listener | actionable (`ViewRules.kt:33-34`) |

- `PreparedLayoutTextView` extends `ViewGroup`, so it would **not** be masked. Its flag
  `enablePreparedTextLayout` is off by default in 0.88.1 [javap]. Do not turn it on.
- **`<Tugboat.Sensitive>`** is a Fabric view (`collapsable={false}`, kept by Fabric
  [spike 15.6]) whose Android view calls `tugboatSensitive()` when created
  (`TugboatTag.kt:39-42`). The mask walk then covers it and every view below it, each at
  its own bounds (`MaskWalk.kt:46,57`). No `<Tugboat.Mask override>` in 0.0.1.
- `maskLevel` accepts only `'allTextAndMedia'`; any other string becomes
  `allTextAndMedia` (`native-capture-contracts.md:190-196`).
- **Late start is the one real blocker.** The SDK only knows activities created after
  its first `start` (`Tugboat.kt:44-48`, `LiveActivities.kt:6-9`), and JavaScript runs
  after the activity resumed. Fix: a `ContentProvider` in the package installs the
  observation before any activity exists (new seam, task A). A later `start` then
  attaches to the resumed activity (`ViewsAdapter.kt:136-142`).
- Gaps: custom-drawn views (`react-native-svg`, Skia, maps) are not classified, as in
  the native SDK (contract Difference 5); wrap them in `<Tugboat.Sensitive>`. A `Modal`
  is a Dialog window: frames carry `overlayWindow`, its pixels are not captured.

## 3. Fingerprints

**Choice: the native Views identity of the hit view, not the JavaScript fiber.** It needs
no touch handler, no fiber walk and no hold-and-match between threads, and it is already
tested (`AnchorResolver.kt:31-39`).

| Anchor field | Value in 0.0.1 |
| --- | --- |
| `toolkit` | `view` (`TargetAnchor.kt:55`). Not `react-native`: that name is reserved for the fiber canonicalization of design note section 10. |
| `widgetType` | nearest `android.*` class (`PlatformToken.kt:22-29`): `ViewGroup`, `TextView`, `EditText`, `ScrollView`, `HorizontalScrollView`, `ImageView`, `CompoundButton` (a `Switch`). Not changed by R8. |
| `canonicalPath` | kept views only, `Token#ordinal`, or `Token#<testID>` when the view has a `testID` (`CanonicalPath.kt:56-67`) |
| `routeKey` | the screen name from `Tugboat.setScreen` (section 4); before the first call, the activity class name |
| `tag`, `tagFingerprint` | the `testID` (`AnchorResolver.kt:74-78`). The unique-id check counts Android view ids (`IdCounts.kt:27`), and every React view has its own, so a repeated `testID` is not filtered out in 0.0.1. |
| `fingerprint` | hash of `routeKey` + `canonicalPath`; `medium` with an own `testID`, else `low` (`AnchorResolver.kt:68-72`) |

- **`testID`:** React Native stores it in the view tag `R.id.react_test_id` [javap,
  `BaseViewManager.setTestId`]. The Views adapter reads names through the `ResourceNames`
  interface (`ResourceNames.kt:8-10`, built at `ViewsAdapter.kt:77-78`); React tags are
  not resource ids (`ResourceNames.kt:42`). Task A adds a hook so the package can supply
  the `testID` as that name. A `testID` also keeps a view from being flattened.
- **Stable per build:** yes for the same screen state. Flattening is fixed for a given
  build, and tokens are platform classes.
- **Not stable:** rows of a long `FlatList`. There is no `[item:N]` (no `RecyclerView`),
  so a row's ordinal counts mounted rows. Give rows a `testID`.
- `Text` with `onPress` is not clickable natively [javap: no click listener in
  `ReactTextViewManager`], so it anchors as a `TextView` with no role.
- These fingerprints will change in 0.1.0. Do not keep them.

## 4. Screens

```ts
Tugboat.setScreen(name, instanceId?)       // custom navigators
Tugboat.trackNavigation(navigationRef)     // React Navigation: calls setScreen
```

`trackNavigation` listens to `state` and `ready`, and sends the focused path of route
names (`Main/Feed`) with the leaf `route.key` as the instance id.

Native reuses the Jetpack Navigation path, which already does everything needed:
`Tugboat.setScreen` calls `NavigationObservation.onNavDestination`
(`NavigationObservation.kt:139-155`) with the resumed activity. That sets the route key
of every view in the activity (`DestinationTracker.kt:24-27`, `ViewRouteResolver.kt:45-48`)
and sends a `navigation` fact: `pop` when the instance id is already on the stack, else
`push` (`ControllerNavigation.kt:43-48`). Session-start seeds come with it. A path keeps
its slashes (`RoutePattern.kt:10-16`). The route `type` is `NavDestination`.

`react-native-screens` puts each screen in an androidx Fragment [unverified, from
memory]. Fragment tracking is recursive (`FragmentNavigation.kt:67`) and would add a
second navigator whose route name is the fragment class (`FragmentNavigation.kt:182-193`),
and would fix a screen's route key before JavaScript names it. Task A adds a filter; the
package ignores `com.swmansion.rnscreens.*`. A tab switch back to a visited tab is
recorded as a `pop`.

## 5. Network

**Choice: the OkHttp interceptor.** Both ways see `fetch` and `XMLHttpRequest` on
Android [spike 15.1]. The interceptor is about ten lines of Kotlin and reuses
`TugboatOkHttpInterceptor` (`TugboatOkHttpInterceptor.kt:56`). The custom builder is
applied on every request [javap, `sendRequestInternalReal`], so it can be set at `start`.

```kotlin
NetworkingModule.setCustomClientBuilder { it.addInterceptor(TugboatOkHttpInterceptor(::route)) }
```

- `route` is the URL path, no query (`Tugboat.kt:388-393`). Optional `networkAllowHosts`.
- **No double recording:** 0.0.1 has no JavaScript wrapper, and a second interceptor on
  the same call records nothing (`TugboatOkHttpInterceptor.kt:77-78`).
- Limits: it replaces an app's own `setCustomClientBuilder` (there is one slot). Image
  loads and `WebView` are not seen. Debug builds also record Metro's requests.

## 6. JavaScript API

```ts
Tugboat.start({
  collector: { baseUrl, apiKey },                       // CollectorConfig
  app: { name, version?, buildNumber?, appId?, installationId? },   // AppInfo
  enabled: true,                    // default false: dormant until activate()
  maskLevel: 'allTextAndMedia',
  captureFocusChanges, captureSystemInput, captureDiagnostics, durableOutbox,   // optional
  captureNetwork: true, networkAllowHosts: [],
});
Tugboat.activate(id); Tugboat.deactivate(); Tugboat.stop();
Tugboat.setUserId(id); Tugboat.setTraits({...});
```

Names follow `TugboatConfig.kt:8-90`. `version`, `buildNumber` and `appId` default to the
app's package info. Each method is one call to the same-named `Tugboat` function
(`Tugboat.kt:182,225,251,281,292,314`). Nothing throws into the app. On iOS every call is
a no-op with one warning.

## 7. Not in 0.0.1

iOS; fiber identity and `toolkit: react-native`; `[item:N]` and `[page:N]`; cross-OS
fingerprints; `<Tugboat.Mask>` and the expected-marks protocol; a new session on JS
reload; boxing unknown native views; the JS network wrapper and a JS route resolver;
Expo; publishing. Sessions report as the Android SDK, with no React Native marker.

## 8. Tasks

A and B can run in parallel. C needs both. B and C need the sample-app PR merged.

**A. `tugboat-android` seams** (Kotlin only, about 80 lines plus tests)
- `Tugboat.kt`: `setScreen(name, instanceId = name)`.
- `adapter/TugboatAdapters.kt`: `install(application)` (calls
  `NavigationObservation.ensureInstalled`), a view-name provider, a fragment filter.
- `views/ViewsAdapter.kt:77`: names fall back to the provider.
  `views/navigation/FragmentNavigation.kt:130,144`: skip filtered fragments.
- Robolectric tests: a late `start` attaches to a resumed activity; `setScreen` gives
  push, pop and the route key; a provided name gives the path segment and the alias; a
  filtered fragment sends no fact.
- Verify: `:tugboat-android:testDebugUnitTest`, and
  `BASE_SHA=origin/main bash tool/ci/check-version-policy.sh`.

**B. The package, on today's public API** (`sdks/react-native/`)
- `package.json`, `src/index.ts`, `src/NativeTugboat.ts`,
  `src/TugboatSensitiveViewNativeComponent.ts`, `android/build.gradle`,
  `android/src/main/java/com/tugboat/reactnative/{TugboatPackage,TugboatModule,TugboatSensitiveViewManager,TugboatNetwork}.kt`.
- Sample: dependency, Metro config, the Maven repository, `src/tugboat.ts` (`start`, and
  `Sensitive` around the card fields), `README` with the publish command.
- First check on the phone: the app launches (`Tugboat.kt` references
  `androidx.navigation`, which the app does not have; expected to load, [unverified]).
- Verify on the phone with the capture collector (`tool/dev/capture-collector`,
  `adb reverse tcp:3000 tcp:3000`). Press Home and reopen once (late start, fixed in C).
  Expect `session_start`, frames with text, images and the card fields filled, `tap`
  events with `toolkit: view`, `scroll` events, and `network_call` for `fetch` and
  `XMLHttpRequest`.

**C. Wire the seams** (after A and B)
- `android/.../TugboatInitProvider.kt` and its manifest entry: `TugboatAdapters.install`,
  the `testID` provider, the fragment filter.
- `TugboatModule.setScreen`, `src/index.ts` `setScreen` and `trackNavigation`; the sample
  calls `trackNavigation` in its root.
- Verify on the phone: frames from a cold launch with no Home press; one `route_change`
  per navigation, with `Main/Feed` names and no `ScreenStackFragment`
  (`adb shell dumpsys activity top | grep -i fragment` shows whether the fragments exist);
  the same button gives the same fingerprint in two launches of one APK; `tag` is the
  `testID`. Then run the collector's compare mode against a Flutter example run: the
  same keys per event type; values differ.
