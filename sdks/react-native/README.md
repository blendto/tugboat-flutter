# React Native adapter

`@tugboat/react-native` 0.0.3: Android only, unpublished. A thin TurboModule over
`tugboat-android`. React Native draws real Android Views, so the Views adapter
records frames, masks, taps and scrolls as in a native app. JavaScript starts the
SDK and marks sensitive regions; events are built by the shared C++ engine, never
in JavaScript. iOS calls are no-ops with one warning. Raw pixels never enter
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

## Build against the in-repo Android SDK

The Android library depends on `tugboat-android` and `tugboat-okhttp` from the
git-ignored `.local-maven`. Publish them first (needs the NDK in `AGENTS.md`):

```sh
cd platforms/android && ./gradlew :capture-runtime:publishAllPublicationsToLocalCaptureRepository \
  :tugboat-android:publishAllPublicationsToLocalCaptureRepository \
  :tugboat-okhttp:publishAllPublicationsToLocalCaptureRepository
```

Then build `example/` (see its README). Known gaps in 0.0.3:
- Screens: `Tugboat.trackNavigation(navigationRef)` (React Navigation) or
  `Tugboat.setScreen(name, instanceId?)`. A `testID` is the view's tag and
  fingerprint name. A content provider installs the observation before the first
  activity, so `Tugboat.start` may run late.
- Not yet handled: the screen name is lost when the activity is recreated; a
  `setScreen` while the activity is paused is dropped; a reused instance id with
  a new name keeps the old name; a `testID` containing `#` or `/` is not escaped
  in the canonical path; a late `start` skips launch correlation until the next
  resume.
- Network: a call whose URL path has percent-encoded characters (spaces,
  non-ASCII) is not recorded. `captureNetwork: false` leaves an app's own
  `setCustomClientBuilder` alone; the default replaces it.
- `<Tugboat.Sensitive>` is a real view on Android; on iOS it renders its
  children only (no wrapper view, `style` ignored).
- If the native module is not linked on Android, calls warn "only Android is
  supported" (misleading) and `<Tugboat.Sensitive>` fails to render.
