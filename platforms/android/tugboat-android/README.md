# tugboat-android

Native Android host for the session engine
([ADR 0009](../../../docs/decisions/0009-shared-session-engine.md)).
Maven coordinates `com.gettugboat.sdk:tugboat-android:0.1.0`, namespace
`com.tugboat.android`, minSdk 24. Versioned on its own (ADR 0008, see
[CHANGELOG](CHANGELOG.md)) and unpublished: the only repository is the
untracked `.local-maven`.

Status: the native Android SDK for Views apps, end to end: public facade,
engine wiring, window capture with masks, and a sample app
([`tugboat-sample`](../tugboat-sample/README.md)). The public API is the
`com.tugboat.android` package below; everything else is `internal`.

## Public API

```kotlin
// Application.onCreate
Tugboat.start(application, TugboatConfig(
    collector = CollectorConfig(baseUrl, apiKey),
    app = AppInfo(name, version, buildNumber, appId, installationId),
    maskLevel = MaskLevel.AllTextAndMedia,   // default, the only level
    captureFocusChanges = false,             // engine capability focusChanges
    captureSystemInput = false,              // engine capability systemInput
))
Tugboat.setUserId(id); Tugboat.setTraits(map); Tugboat.stop()
Tugboat.trackNavigation(navController)       // Jetpack Navigation, optional
view.tugboatTag = "checkout"                  // developer alias
```

- Every method can be called from any thread; the work runs on the main
  thread in call order. Nothing throws into the app: failures are logged
  (tag `Tugboat`) and capture stops.
- `start` is idempotent while started. It **refuses to start** (and logs the
  missing paths) when a field the collector requires on `session_start` is
  blank: app version, build number, app id, installation id, name; device id,
  screen size and densities; the locale; the collector URL and key.
- `stop` detaches every observer, posts `session.end`, waits for the
  `session_end` post to settle (accepted, or a status the engine does not
  retry), then submits `engine.dispose` and destroys the handle. The wait is
  bounded at 25 s (`endDrainTimeoutMs` + one `jsonTimeoutMs` + slack); it
  never blocks the app. A later `start` creates a new engine and session.
- `setUserId` / `setTraits` survive `stop` and `start`. Traits JSON cannot
  carry (NaN, infinities) are ignored and logged.
- `trackNavigation` needs `androidx.navigation` in the app (`compileOnly`
  here). Destination route patterns (else the id's entry name) become route
  keys for the controller's activity.

## What it contains

| Piece | Where | Role |
| --- | --- | --- |
| Engine library | `src/main/cpp` | CMake builds `core/session-engine` (target `tugboat_session_engine`) into `libtugboat_engine.so` with `c++_static`, plus a JNI bridge: `create`, `submit`, `destroy`. Only the JNI symbols are exported. |
| Bridge | `engine/NativeEngine`, `JniEngineTransport` | `submit` copies the engine-owned response into a Java `byte[]` before returning. No exception crosses JNI; `EngineStatus` mirrors `tb_session_status`. |
| Host | `host/EngineHost` | Owns one handle and one `HandlerThread("tugboat-engine")`. See the threading notes below. |
| Clock | `host/HostClock` | `monoUs` in the `SystemClock.uptimeMillis` timebase (`uptimeNanos` on API 35+), `wallUs` from `currentTimeMillis`. |
| Effects | `host/Effect`, `EffectDispatcher` | `timer.schedule` / `timer.cancel` go to `TimerExecutor` (`Handler.postAtTime`). `http.send` goes to `HttpExecutor`. `frame.release` goes to `FrameHandleTable`. Unknown types are logged once. |
| HTTP | `host/HttpExecutor`, `RequestDeadline`, `CollectorResponse`, `MultipartBody` | `HttpURLConnection` on one `tugboat-io` thread, with the Flutter collector headers and multipart layout. `jsonBody` is sent byte for byte. `timeoutMs` is a total deadline: a watchdog disconnects at it. Every answer is one the engine accepts: the body is cut to at most 64 KiB at a UTF-8 boundary, and a status outside 100–599 becomes `error`. The multipart bytes are pinned by `conformance/host/multipart-request.golden`, shared with the Apple host. |

| Views adapter | `views/` | Turns activity windows into engine facts and computes masks (below). |
| Facade | `Tugboat`, `TugboatConfig`, `TugboatTag` | The public API above; thin over `sdk/TugboatRuntime`. |
| Engine wiring | `sdk/` | `TugboatRuntime` (composition root: one engine, one session), `HostMetadata` + `DeviceSnapshot` (`engine.configure.host`, refused when incomplete), `EngineConfiguration`, `SessionMessages`, `AppLifecycleBridge` (`ProcessLifecycleOwner` to `app.lifecycle`), `SessionEndWatcher` + `StopSequence` (stop order), `NavigationTracking`. |
| Capture | `capture/` | `CaptureCoordinator` answers `capture.request`; `RuntimeOutcomes` maps `capture-runtime` results; `CaptureResultJson`; `ForegroundWindow` + `SurfaceReporter` (`surface` facts); `CaptureGeometry`; `StructureSignature`. |

`engine.configure` (`sdk/EngineConfiguration`): `host` with every
`session_start` field (`ipInfo.ip` is the placeholder `10.0.2.2`, as
Flutter's Android host sends); `limits` at the Dart defaults; `gesture` from
the adapter's `GestureConfig.toEngineJson()`; `capture.answerTimeoutMs` 5000;
`collector.enabled`; `capabilities.focusChanges` / `systemInput` from the
config. Then `session.start {viewport (dp), platform: android, sessionEpoch,
locale}`.

## Capture

`capture.request` effects (stateful-engine.md 8.2) go to
`capture/CaptureCoordinator`:

1. The request hops from the engine thread to the main thread. There the
   foreground activity's window (`ForegroundWindow`), its decor size, and its
   masks (`ViewsAdapter.masks`, fail-closed) are read.
2. `capture-runtime`'s `capture(window, …)` copies the window (`PixelCopy`,
   API 26+), fills the masks before encoding, and encodes a JPEG at 0.75
   pixels per dp (Flutter's `capturePixelRatio`) times the request's `scale`.
3. The JPEG goes into the handle table and `capture.result` is posted with
   `requestedBackend` = `resolvedBackend` = `nativeCpuExperimental` (the
   collector's closed enum), the boundary rect in dp, a structure
   signature, and timings.

- **Every request is answered exactly once, by id (C16).** Requests can
  overlap; each has its own runtime id and is answered when its result
  arrives, in any order. A late answer is ignored by the engine after its C18
  deadline.
- **dHash baseline.** Offered to the runtime only for a request that is not
  forced and whose `structureSignature` (a hash of decor size and mask
  rectangles) equals the current one. A runtime skip is answered `captured`
  with the baseline's dHash, so the engine coalesces it. Forced requests
  always get a fresh frame; `paintUnchanged` is never sent.
- **Status mapping** (`RuntimeOutcomes`): `Ok` to `captured`;
  `SecureWindow` and `PixelCopyFailed` to `failed readbackFailed`;
  `UnsupportedApi`, `SurfaceUnavailable`, `UnsupportedRenderMode` to `failed
  boundaryUnavailable`; `Timeout` to `failed paintTimedOut`;
  `ProcessingFailed` to `failed encodingFailed`; `Cancelled` and `Disposed` to
  `cancelled`. No foreground window is `boundaryUnavailable`, an unlaid-out
  decor `layoutUnavailable`, a throwing mask path `maskFailed`.
- **`surface` facts.** The foreground decor view's size in dp, reported on
  resume and on every layout change that alters it; the generation advances
  with each change (rotation), starting at 0 so the session's initial capture
  stays current.

`EngineHost` threading and failure rules:

- `post(type, inputJson, at, frameHandles)` and `postBatch` can be called from
  any thread. Callers pass the time the fact happened. `postUntimed` is for
  `engine.configure`, queries, and stateless messages.
- Submits run serialized on the engine thread.
- A non-`ok` status is logged. The message is dropped and its frame handles
  are released.
- Three `internal_error`s in a row shut the host down.
- Shutting down (`close`, or the `internal_error` limit) first submits
  `engine.dispose` so the engine can report undelivered work. From its
  response `frame.release` runs, but no `http.send` or `timer.schedule`
  starts. Then the handle is destroyed.
- Nothing thrown on the engine or IO thread escapes.

## Views adapter

`views/ViewsAdapter` registers `ActivityLifecycleCallbacks` and produces the
facts of the stateful engine (`core/session-engine/docs/stateful-engine.md`
8.1 and 9.1). Facts are timestamped when they happen and posted once per
frame (`Choreographer`) as one `batch` through `EngineHost::postBatch`.

| Fact | Source | Piece |
| --- | --- | --- |
| `input.pointer` | `Window.Callback.dispatchTouchEvent`, observed before the app | `callback/`, `input/PointerFactProducer` |
| tap evidence | hit-test at the down point on an `up` within `touchSlop` | `identity/AnchorResolver` |
| `scroll` | `OnScrollChangedListener` + offset diff; `RecyclerView.OnScrollListener` | `scroll/` |
| `navigation` | activity lifecycle; androidx fragment lifecycle (recursive) | `navigation/` |
| `focus` | `OnGlobalFocusChangeListener` | `input/FocusFactProducer` |
| `systemInput` | allowlisted key-downs in `dispatchKeyEvent` | `input/SystemInputProducer` |

- **Units.** Coordinates and scroll offsets are logical pixels (dp). The
  host must send `GestureConfig.toEngineJson()` (from `ViewConfiguration`) as
  `engine.configure.gesture`, so the engine and the adapter's tap check use
  the same slop.
- **Pointer ids.** Android recycles pointer ids; each contact gets a new,
  process-wide increasing `pointerId`.
- **Identity.** `docs/design/capture-and-fingerprint.md`, "Android Views
  canonicalization". The fingerprint is hashed in Kotlin and tested against
  every `conformance/fingerprint/identity_parts` vector.
- **Masks.** `WindowMasks.compute(window)` returns rectangles normalized to
  the decor view (the `capture-runtime` window rule): `TextView`,
  `ImageView`, `VideoView`, and fail-closed `WebView` / `SurfaceView` /
  `TextureView` / Compose host (`ComposeView`, matched by class name)
  bounds. It masks the whole frame when the tree cannot be
  read.
- **Optional androidx.** `core`, `fragment`, and `recyclerview` are
  `compileOnly`; each is probed once with `Class.forName` and its
  implementation used only when the app ships it. `consumer-rules.pro`
  silences R8 for apps without them and keeps the probed names.
- **`Window.Callback`.** The wrapper is Java (`ObservingWindowCallback.java`)
  so platform `null`s never meet Kotlin null checks; every method is
  forwarded to the replaced callback exactly once. On create and every
  resume it wraps only when no Tugboat wrapper is reachable in the chain:
  `CallbackChain` follows Tugboat's delegate, public `getWrapped()` /
  `getDelegate()` accessors, and `Window.Callback` fields of non-platform
  wrapper classes, up to 16 links. A per-thread dispatch depth keeps facts
  single if two wrappers still end up in one chain.
- **Stop.** After `stop()` nothing is emitted: window, fragment, and
  lifecycle callbacks are removed, and every fact path is gated.
- **Navigation gate.** `ViewsAdapter(postNavigationFacts = false)` (the
  default) tracks navigation for route keys but posts no `navigation` facts;
  the SDK (`TugboatRuntime`) turns it on now that the engine has phase 3d.
- **Motion fails closed.** A running legacy `Animation` (activity and
  fragment transitions) or `LayoutTransition` on a visible view draws away
  from layout bounds, so `WindowMasks` masks the whole frame
  (`FailClosedReason.Animating`); the frame is still captured, fully masked.
  `ViewPropertyAnimator` motion is in the bounds and needs no fallback.
- **Failures.** Every adapter callback is guarded; the first failure per site
  is logged and nothing reaches the app.

Activities the system destroys without finishing (configuration change,
back-stack reclaim) keep their route identity when recreated.

Known gaps: dialog and popup windows are not wrapped for pointer facts and
are not in the captured frame (the copy is the activity window); predictive
back is not observed; overscroll is reported for `RecyclerView` only;
fragment `hide`/`show` is not reported; `transitionMs` is 0; window-manager
activity transitions (not view animations) are not detected for the motion
fallback; a secure window is reported as `failed readbackFailed`, the
closest value in the engine's closed failure vocabulary.

## Build and test

From `platforms/android`:

```sh
./gradlew :tugboat-android:test                 # JVM + Robolectric unit tests
./gradlew :tugboat-android:assembleAndroidTest  # instrumented APK (real JNI)
./gradlew :tugboat-android:connectedAndroidTest # needs a device or emulator
```

`bash tool/ci/build-android-runtime.sh` from the repository root runs the first
two, builds the release AAR, and assembles the sample's debug APK.
`android-runtime-device.yml` runs the instrumented tests on API 26 and 34
emulators.

Instrumented tests load the real library:

- `NativeEngineTest` checks the `fingerprint.labelHash` conformance fixture
  through JNI.
- `sdk/CollectorContractTest` is the collector contract test (native SDK
  note section 8): it drives the real engine through `EngineHost` with the
  SDK's own `engine.configure`, `session.start`, and `capture.result`
  builders and a recording transport, and pins the `session_start` body
  (app version and build number, device with screen size and densities,
  `ipInfo.ip`, locale) and `frameMetadata[].requestedBackend` /
  `resolvedBackend` = `nativeCpuExperimental`.

JVM tests pin the host's side of the same contract (`HostMetadataTest`,
`CaptureResultJsonTest`).
