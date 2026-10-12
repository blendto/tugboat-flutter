# tugboat-android

Native Android host for the session engine
([ADR 0009](../../../docs/decisions/0009-shared-session-engine.md)).
Maven coordinates `com.gettugboat.sdk:tugboat-android:0.1.0`, namespace
`com.tugboat.android`, minSdk 24. Versioned on its own (ADR 0008, see
[CHANGELOG](CHANGELOG.md)) and unpublished: the only repository is the
untracked `.local-maven`.

Status: platform plumbing and the Android Views toolkit adapter. There is no
app API yet. The only public types are the opt-in toolkit-region seam
(`com.tugboat.android.toolkit`, below), which `tugboat-compose` implements;
everything else is `internal`.

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
  `ImageView`, `VideoView`, toolkit region masks, and fail-closed
  `WebView` / `SurfaceView` / `TextureView` bounds. A Compose host
  (`ComposeView`, matched by class name) that no region reads is
  fail-closed too. It masks the whole frame when the tree cannot be read,
  or when a region asks for it.
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
- **Navigation gate.** `navigation` is a phase 3d engine message, so
  `ViewsAdapter(postNavigationFacts = false)` (the default) tracks navigation
  for route keys but posts no `navigation` facts until 3d.
- **Failures.** Every adapter callback is guarded; the first failure per site
  is logged and nothing reaches the app.

## Toolkit-region seam

Some toolkits draw their whole UI inside one View (Compose's
`AndroidComposeView`). A toolkit module reads that content for the Views
adapter by registering a `ToolkitRegion` with `ToolkitRegions.register`.
The types live in `com.tugboat.android.toolkit` and need
`@OptIn(TugboatToolkitApi::class)`: they are public only because Kotlin
`internal` does not cross modules, and are not app API. No toolkit type
crosses the seam; everything is Views, `RectF`, and plain values.

```kotlin
interface ToolkitRegion {
    val toolkit: String                       // anchor toolkit, e.g. "compose"
    val hostToken: String                     // path token of the host view, e.g. "Compose"
    fun hosts(view: View): Boolean
    fun targetAt(host: View, x: Float, y: Float): RegionHit   // Target | Unreadable | Miss
    fun scrollables(host: View): List<RegionScrollable>
    fun masks(host: View): RegionMasks                         // host-pixel rects, or wholeFrame
    fun focus(host: View): RegionFocus?                        // TextInput | Other
    fun routeKey(host: View): String?
    fun onDestinationChanged(activity: Activity, route: String?)
}
```

How the Views adapter uses it (`views/region/RegionHost` guards every call;
a throw counts as "cannot read"):

| Concern | Rule |
| --- | --- |
| Taps | The hit view's nearest region host answers first. `Target`: an anchor whose path is the host's Views path plus the region's segments, hashed with the region's route key (or the host's Views route), with the region's `toolkit`. `Unreadable`: the host view itself, with the region's `toolkit` and `hostToken`. `Miss`: the Views rules continue from the hit view. |
| Identity | A region host is a kept view whose token is `hostToken`, so sibling hosts get ordinals and paths stay unique. |
| Masks | A region host's rects replace walking it; `wholeFrame` masks the whole frame. A name-matched Compose host whose direct child is a region host is no longer fail-closed. |
| Scroll | `scroll/RegionScrollTracker`: region scrollables are sampled at a gesture's first `down`, then diffed every frame while a pointer is down and for 1 s after (flings); 150 ms idle ends a scroll. Ids are `<toolkit>-scroll-<n>`. |
| Focus | When a region host has View focus, its region reports the kind; it is re-read for four frames after each touch-up or key event, because region focus moves without a View focus change. |
| Navigation | `onDestinationChanged(activity, route, id)` forwards the plain route to every region. |

Activities the system destroys without finishing (configuration change,
back-stack reclaim) keep their route identity when recreated.

Known gaps: dialog and popup windows are not wrapped for pointer facts;
predictive back is not observed; overscroll is reported for `RecyclerView`
only; fragment `hide`/`show` is not reported; `transitionMs` is 0.

## Build and test

From `platforms/android`:

```sh
./gradlew :tugboat-android:test                 # JVM + Robolectric unit tests
./gradlew :tugboat-android:assembleAndroidTest  # instrumented APK (real JNI)
./gradlew :tugboat-android:connectedAndroidTest # needs a device or emulator
```

`bash tool/ci/build-android-runtime.sh` from the repository root runs the first
two and builds the release AAR.

The instrumented test loads the real library and checks the
`fingerprint.labelHash` conformance fixture through JNI.
