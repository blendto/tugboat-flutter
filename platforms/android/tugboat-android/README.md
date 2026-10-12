# tugboat-android

Native Android host for the session engine
([ADR 0009](../../../docs/decisions/0009-shared-session-engine.md)).
Maven coordinates `com.gettugboat.sdk:tugboat-android:0.1.0`, namespace
`com.tugboat.android`, minSdk 24. Versioned on its own (ADR 0008, see
[CHANGELOG](CHANGELOG.md)) and unpublished: the only repository is the
untracked `.local-maven`.

Status: platform plumbing and the Android Views toolkit adapter. There is no
public API yet; every Kotlin type is `internal`.

## What it contains

| Piece | Where | Role |
| --- | --- | --- |
| Engine library | `src/main/cpp` | CMake builds `core/session-engine` (target `tugboat_session_engine`) into `libtugboat_engine.so` with `c++_static`, plus a JNI bridge: `create`, `submit`, `destroy`. Only the JNI symbols are exported. |
| Bridge | `engine/NativeEngine`, `JniEngineTransport` | `submit` copies the engine-owned response into a Java `byte[]` before returning. No exception crosses JNI; `EngineStatus` mirrors `tb_session_status`. |
| Host | `host/EngineHost` | Owns one handle and one `HandlerThread("tugboat-engine")`. See the threading notes below. |
| Clock | `host/HostClock` | `monoUs` in the `SystemClock.uptimeMillis` timebase (`uptimeNanos` on API 35+), `wallUs` from `currentTimeMillis`. |
| Effects | `host/Effect`, `EffectDispatcher` | `timer.schedule` / `timer.cancel` go to `TimerExecutor` (`Handler.postAtTime`). `http.send` goes to `HttpExecutor`. `frame.release` goes to `FrameHandleTable`. Unknown types are logged once. |
| HTTP | `host/HttpExecutor`, `RequestDeadline`, `MultipartBody` | `HttpURLConnection` on one `tugboat-io` thread, with the Flutter collector headers and multipart layout. `jsonBody` is sent byte for byte. `timeoutMs` is a total deadline: a watchdog disconnects at it. The response body is capped at 64 KiB. |

| Views adapter | `views/` | Turns activity windows into engine facts and computes masks (below). |

`EngineHost` threading and failure rules:

- `post(type, inputJson, at, frameHandles)` and `postBatch` can be called from
  any thread. Callers pass the time the fact happened. `postUntimed` is for
  `engine.configure`, queries, and stateless messages.
- Submits run serialized on the engine thread.
- A non-`ok` status is logged. The message is dropped and its frame handles
  are released.
- Three `internal_error`s in a row shut the host down.
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
  `TextureView` bounds. It masks the whole frame when the tree cannot be
  read.
- **Optional androidx.** `core`, `fragment`, and `recyclerview` are
  `compileOnly`; each is probed with `Class.forName` and used only when the
  app ships it.
- **`Window.Callback`.** Every method is forwarded to the replaced callback
  exactly once. A marker interface prevents double wrapping; on each resume a
  callback another SDK replaced is wrapped again, and only the outermost
  Tugboat wrapper observes.
- **Failures.** Every adapter callback is guarded; the first failure per site
  is logged and nothing reaches the app.

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
