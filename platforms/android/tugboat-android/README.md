# tugboat-android

Native Android host for the session engine
([ADR 0009](../../../docs/decisions/0009-shared-session-engine.md)).
Maven coordinates `com.gettugboat.sdk:tugboat-android:0.1.0`, namespace
`com.tugboat.android`, minSdk 24. Versioned on its own (ADR 0008) and
unpublished: the only repository is the untracked `.local-maven`.

Status: platform plumbing only. There is no public API and no toolkit adapter
yet; every Kotlin type is `internal`.

## What it contains

| Piece | Where | Role |
| --- | --- | --- |
| Engine library | `src/main/cpp` | CMake builds `core/session-engine` (target `tugboat_session_engine`) into `libtugboat_engine.so` with `c++_static`, plus a JNI bridge: `create`, `submit`, `destroy`. Only the JNI symbols are exported. |
| Bridge | `engine/NativeEngine`, `JniEngineTransport` | `submit` copies the engine-owned response into a Java `byte[]` before returning. No exception crosses JNI; `EngineStatus` mirrors `tb_session_status`. |
| Host | `host/EngineHost` | Owns one handle and one `HandlerThread("tugboat-engine")`. `post` / `postBatch` / `postUntimed` from any thread; submits run serialized on that thread. Non-`ok` statuses are logged and dropped. Three `internal_error`s in a row shut the host down. |
| Clock | `host/HostClock` | `monoUs` in the `SystemClock.uptimeMillis` timebase (`uptimeNanos` on API 35+), `wallUs` from `currentTimeMillis`. `post` adds `at` unless the message has one. |
| Effects | `host/Effect`, `EffectDispatcher` | `timer.schedule` / `timer.cancel` go to `TimerExecutor` (`Handler.postAtTime`). `http.send` goes to `HttpExecutor` (`HttpURLConnection` on one `tugboat-io` thread, Flutter collector headers, 64 KiB response body cap). `frame.release` goes to `FrameHandleTable`. Unknown types are logged once. |

`postUntimed` exists because the engine rejects `at` on `engine.configure`,
queries, and stateless messages.

JSON bodies from `http.send` are sent byte for byte. The host never re-encodes
engine or caller JSON (`RawJson` slices it), so `390.0` stays `390.0`.

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
