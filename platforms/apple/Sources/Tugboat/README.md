# Tugboat (SwiftUI SDK)

The native SwiftUI SDK on the session engine
([ADR 0009](../../../../docs/decisions/0009-shared-session-engine.md)).
SwiftPM product and module `Tugboat` in the root `Package.swift`, iOS 15+,
depending on the internal `TugboatSessionEngine` target and (on iOS) the
`TugboatCaptureRuntime` pixel runtime. Versioned on its own (ADR 0008): the
version is `TugboatVersion.current` in `TugboatVersion.swift`, sent as
`X-Sdk-Version` (see [CHANGELOG](CHANGELOG.md)). Unpublished: no podspec yet
(it will be `TugboatSDK`, module `Tugboat`). It mirrors the Android SDK in
`platforms/android/tugboat-android`. The sample app is
[`Samples/TugboatSwiftUISample`](../../Samples/TugboatSwiftUISample/README.md).

## Public API (native SDK note section 3)

```swift
Tugboat.start(TugboatConfig(
  collector: .init(baseURL: url, apiKey: key),
  app: .init(name: name, version: version, buildNumber: build, appId: bundleId, installationId: installId),
  captureFocusChanges: true))           // optional; also captureSystemInput, trackHostingControllers
Tugboat.setUserId("user-1")             // nil clears; kept across stop/start
Tugboat.setTraits(["plan": "pro"])      // JSON values; kept across stop/start
Tugboat.stop()
someView.tugboatTag("checkout")         // developer alias for a target
someView.tugboatScreen("Checkout")      // route identity for a screen
```

- Call `start` from `application(_:didFinishLaunchingWithOptions:)` (SwiftUI
  apps use `@UIApplicationDelegateAdaptor`). Every method may be called from
  any thread; work runs on the main thread in call order.
- `start` is idempotent. It refuses to start, and logs the field paths, when
  a field the collector requires on `session_start` is blank or invalid
  (`app.version`, `app.buildNumber`, device screen metrics, locale, …) or the
  collector URL is not http(s).
- Nothing throws or traps into the app; failures are logged under subsystem
  `com.gettugboat.sdk`.
- `stop` ends the session, then disposes the engine once the `session_end`
  post settled (202 or a status the engine does not retry), or after 25 s,
  on a background queue. The main thread never waits.

## SDK wiring (`Public/`, `Sdk/`, `Capture/`)

| Piece | Where | Role |
| --- | --- | --- |
| Facade | `Public/Tugboat`, `TugboatConfig` | Thin: main-thread hop, idempotency, user id and traits kept across sessions. |
| Composition root | `Sdk/TugboatRuntime`, `RuntimeParts` | Builds and owns one engine host, the SwiftUI adapter, the capture coordinator, the surface observer, and the lifecycle bridge. Closures reach the host weakly. |
| Configuration | `Sdk/HostMetadata`, `DeviceSnapshot`, `EngineConfiguration`, `SessionMessages` | `engine.configure`: `host` with every `session_start` field the collector requires (device id `identifierForVendor`, `platform: ios`, screen size in points, `scale` as both densities, dpi `scale × 160`, `ipInfo.ip` placeholder `127.0.0.1` as Flutter on iOS, configured locale with timezone), the Dart `limits`, `gesture` = `GestureConfig.uiKitDefault`, `capture.answerTimeoutMs` 5000, `collector.enabled`, `focusChanges` / `systemInput`. `session.start` with the key window's viewport and the active locale. |
| Lifecycle | `Sdk/AppLifecycleBridge` | Application notifications to `app.lifecycle`: active `resumed`, resign `inactive`, background `paused`, will-enter-foreground `inactive`, terminate `detached`. |
| Stop | `Sdk/StopSequence`, `SessionEndWatcher` | `session.end` → wait for the `session_end` post (bounded, `tugboat.stop` queue) → `engine.dispose` → destroy. The watcher repeats the engine's retry rule; a test pins it to `transport.cpp` and the `delivery-status-classification` fixture. |
| Captures | `Capture/CaptureCoordinator`, `RuntimeOutcomes`, `FrameMasks`, `WindowCapturer` | `capture.request` → main thread → the key window (waits up to 3 s for one) → `TugboatCaptureRuntime` (`viewHierarchy`, the whole `UIWindow`, so sheets and alerts are in the frame). The mask supplier (`WindowMasks`) runs inside the runtime's main-thread draw turn, immediately before each draw, so masks and pixels describe the same layout. JPEG bytes go to `FrameHandleTable`. Every request is answered exactly once by id, in any order (C16); every runtime status maps explicitly. |
| Wire | `Capture/CaptureAnswer`, `CaptureResultJSON`, `MaskCoverageWire`, `EngineVocabulary` | `capture.result` with `requestedBackend` / `resolvedBackend` `nativeCpuExperimental`, the boundary, timings, and the frame's `maskCoverage` (sent once the engine accepts it, `EngineVocabulary.frameMaskCoverage`). |
| Surface | `Capture/SurfaceReporter`, `SurfaceObserver`, `CaptureGeometry` | `surface {boundaryRect, generation}` in window points when the key window's size changes (rotation, resize), checked on key-window, activation and orientation changes and before every capture. Frames are 0.75 px per point × the engine `scale` (Flutter's `capturePixelRatio`). |

## Engine host (`Engine/`, `Host/`, `HTTP/`)

| Piece | Where | Role |
| --- | --- | --- |
| Bridge | `Engine/EngineBridge` | Owns one `tb_session_engine` handle and calls the C ABI directly (no Objective-C++). `submit` copies the engine-owned response into `Data` before returning. Statuses are the imported `tb_session_status` constants. |
| Host | `Host/EngineHost` | Owns the bridge and one serial `DispatchQueue` (`tugboat.engine`). See the threading notes below. |
| Messages | `Host/EngineMessage`, `HostMessages` | Envelopes built by concatenation around the caller's `input` JSON, which is never parsed or re-encoded. |
| Clock | `Host/HostClock` | `monoUs` from `ProcessInfo.systemUptime` (the clock of `UIEvent.timestamp`), `wallUs` from `Date()`. |
| Effects | `Host/Effect`, `EffectParser`, `EffectDispatcher`, `CaptureRequestEffect` | Each response is decoded once (`JSONSerialization`) into typed effects, run in order. `capture.request` goes to the `CaptureRequestSink` (the capture coordinator). Types the host does not execute are logged once per type. |
| Timers | `Host/TimerExecutor` | One `DispatchSourceTimer` per id on the engine queue, armed for the time left until `atMonoUs` (saturating, so any `atMonoUs` is safe). Rescheduling replaces. A fire is stamped no earlier than its `atMonoUs`, or the engine would ignore it as stale. |
| Frames | `Host/FrameHandleTable` | Thread-safe store of JPEG bytes behind never-reused opaque handles. |
| HTTP | `HTTP/HTTPExecutor`, `HTTPSessionDelegate`, `CollectorResponse`, `MultipartBody` | Ephemeral `URLSession` with its delegate queue on `tugboat.io`. Same collector headers and multipart bytes as the Android host and the Flutter `CollectorHttpSink`. `jsonBody` is sent byte for byte. `timeoutMs` is a total deadline (watchdog), redirects are reported and not followed. Every answer is one the engine accepts: the body is cut to at most 64 KiB at a UTF-8 boundary, and a status outside 100–599 becomes `error`. |

## SwiftUI adapter (`SwiftUI/`)

Internal (`SwiftUIAdapter`), main thread only. It produces the facts of
stateful-engine.md sections 8.1 and 9.1 and batches them once per frame
(`CADisplayLink`) into `EngineHost.postBatch`, each with its own time. Rules
are in native SDK note sections 2.1, 5 and 6.3, and in
[capture-and-fingerprint.md](../../../../docs/design/capture-and-fingerprint.md)
(SwiftUI canonicalization).

| Piece | Where | Role |
| --- | --- | --- |
| Facts | `Facts/` | `FactBatcher` (frame hooks, one `batch` per frame), `DisplayLinkFrames`, `FactClock` (`UITouch.timestamp` is `systemUptime`, the host clock), a small ordered JSON writer. |
| Pointer | `Input/WindowPointerRecognizer`, `PointerFactBuilder` | A recognizer on each window that becomes key: never cancels or delays touches, never prevents or is prevented, recognizes simultaneously, no swizzling. `input.pointer` in window points, a unique `pointerId` per contact, tap evidence on `up` under `touchSlop` resolved at the down position. |
| Identity | `Identity/` | `ViewTree` / `ViewKind` classify every view once per walk. `.tugboatTag` markers (`TagMarkerView`, matched within the hit window and hosting root) first, then UIKit hit-testing (text inputs, list cells with index paths, scroll views, representable hosts); route key from `.tugboatScreen`, else the hashed hosting-controller type; `toolkit: "swiftui"`. `IdentityHash` matches every `conformance/fingerprint/identity_parts` vector. |
| Scroll | `Scroll/` | KVO on `contentOffset` of the window's scroll views; `start` (with the anchor), one `update` per frame, one `overscroll` per scroll, `end` when no finger or momentum drives it and it has been still for 100 ms. |
| Navigation | `Navigation/`, `Modifiers/TugboatScreen` | `.tugboatScreen` appear and disappear on navigator `swiftui-screens`; optional hosting-controller appearance (one-time method exchange, opt-out) on `swiftui-hosting` until a screen is seen. |
| Focus | `Input/FocusObserver` | `text_input` / `none` from `UITextField` / `UITextView` editing notifications. |
| Masks | `Mask/` | `masks(for:)`: one view walk plus each view's layers (`LayerWalk`). UIKit text and images; boxes for web views, opaque renderers, app representables and unverified SwiftUI platform views; allowlisted SwiftUI text, image and shape layers per iOS major (`LayerAllowlist`, `KnownPlatformViews`; iOS 26 verified). Unclassified layers are masked. The whole frame is masked on an unverified major with SwiftUI, during any animation, and over the walk's limits. `MaskResult.coverage` summarizes each frame: `precise` or `wholeFrame`, with closed reasons for the host to report. |

Known gaps: no system input facts (none in this milestone); application
lifecycle only (not per scene); no background task keeps delivery running
after the app is suspended (pending events go out on the next foreground).

`EngineHost` threading and failure rules:

- `post(type:inputJSON:at:frameHandles:)` and `postBatch(_:)` can be called
  from any thread. Callers pass the time the fact happened.
  `postUntimed(type:inputJSON:)` is for `engine.configure`, queries, and
  stateless messages.
- Submits, responses, and effects run serialized on the engine queue, in post
  order. Transport results and timer fires come back as messages on it.
- A non-`ok` status is logged. The message is dropped and its frame handles
  are released.
- Shutting down (`close`, or three `internal_error`s in a row) first submits
  `engine.dispose` so the engine can report undelivered work; from its
  response `frame.release` runs but no `http.send`, `timer.schedule`, or
  `capture.request` starts.
  Then timers are cancelled, IO closed, the handle destroyed, and frames
  freed. Posts after that (or after `close`)
  release their frame handles.
- Nothing force-unwraps external data, and no engine or collector value can
  reach a trapping operation: integer conversions and deadlines saturate.

## Build and test

Requires Xcode. From the repository root on a Mac:

```sh
swift build --target Tugboat
xcodebuild test -scheme TugboatCaptureRuntime-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:TugboatTests
```

`TugboatTests` runs the collector contract test (`Sdk/CollectorContractTests`:
the real engine through the host with the SDK's own `engine.configure`,
`session.start` and `capture.result`, pinning the `session_start` body and
`frameMetadata` backends `nativeCpuExperimental`), the capture coordinator
with overlapping requests answered out of order, the bridge against the real
engine (the `fingerprint.labelHash` conformance fixture), the host with a
fake engine and transport, real timers, the multipart golden bytes shared with the Android
host (`conformance/host/multipart-request.golden`), and the HTTP executor against a `URLProtocol` stub.
`TugboatTests/SwiftUI` tests the adapter on hosted SwiftUI views in a test
window, including the layer-allowlist regression guard, which fails when a
screen with text and an image shows no allowlisted layer class on a verified
iOS major.
