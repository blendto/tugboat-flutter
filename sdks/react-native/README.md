# React Native adapter

`@tugboat/react-native` 0.0.1: Android only, unpublished. A thin TurboModule over
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

Then build `example/` (see its README). Known gaps in 0.0.1: the SDK starts after
the activity resumed, so a session begins on the next activity; no screen names
or `testID` fingerprints yet.
