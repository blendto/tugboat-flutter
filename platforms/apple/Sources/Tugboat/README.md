# Tugboat (Swift host)

Native Apple host for the session engine
([ADR 0009](../../../../docs/decisions/0009-shared-session-engine.md)).
SwiftPM product and module `Tugboat` in the root `Package.swift`, iOS 15+,
depending on the internal `TugboatSessionEngine` target. Versioned on its own
(ADR 0008): the version is `TugboatVersion.current` in `TugboatVersion.swift`,
sent as `X-Sdk-Version` (see [CHANGELOG](CHANGELOG.md)). Unpublished: no
podspec yet (it will be `TugboatSDK`, module `Tugboat`).

Status: platform plumbing and the SwiftUI toolkit adapter. The only public
API is two view modifiers, `.tugboatTag(_:)` and `.tugboatScreen(_:)`; the
`Tugboat` facade and the capture wiring are later slices. It mirrors the
Android host in `platforms/android/tugboat-android`.

## What it contains

| Piece | Where | Role |
| --- | --- | --- |
| Bridge | `Engine/EngineBridge` | Owns one `tb_session_engine` handle and calls the C ABI directly (no Objective-C++). `submit` copies the engine-owned response into `Data` before returning. Statuses are the imported `tb_session_status` constants. |
| Host | `Host/EngineHost` | Owns the bridge and one serial `DispatchQueue` (`tugboat.engine`). See the threading notes below. |
| Messages | `Host/EngineMessage`, `HostMessages` | Envelopes built by concatenation around the caller's `input` JSON, which is never parsed or re-encoded. |
| Clock | `Host/HostClock` | `monoUs` from `ProcessInfo.systemUptime` (the clock of `UIEvent.timestamp`), `wallUs` from `Date()`. |
| Effects | `Host/Effect`, `EffectParser`, `EffectDispatcher` | Each response is decoded once (`JSONSerialization`) into typed effects, run in order. Types the host does not execute (including `capture.request` until the toolkit adapters land) are logged once per type. |
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
| Identity | `Identity/` | `.tugboatTag` frames (anchor preferences, `TagRegistry`) first, then UIKit hit-testing (text inputs, list cells with index paths, scroll views, representable hosts); route key from `.tugboatScreen`, else the hashed hosting-controller type; `toolkit: "swiftui"`. `IdentityHash` matches every `conformance/fingerprint/identity_parts` vector. |
| Scroll | `Scroll/` | KVO on `contentOffset` of the window's scroll views; `start` (with the anchor), one `update` per frame, one `overscroll` per scroll, `end` when no finger or momentum drives it and it has been still for 100 ms. |
| Navigation | `Navigation/`, `Modifiers/TugboatScreen` | `.tugboatScreen` appear and disappear on navigator `swiftui-screens`; optional hosting-controller appearance (one-time method exchange, opt-out) on `swiftui-hosting` until a screen is seen. |
| Focus | `Input/FocusObserver` | `text_input` / `none` from `UITextField` / `UITextView` editing notifications. |
| Masks | `Mask/` | `masks(for:)`: UIKit text, images, fail-closed web views and representables, and the allowlisted SwiftUI layers per iOS major (`LayerAllowlist`; iOS 26 verified). Unclassified layers with contents are masked; an unverified major masks a window with SwiftUI in full. |

Known gaps: no system input (none in this milestone); the engine on this
branch rejects `navigation` facts until phase 3d (decisions log).

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
  response `frame.release` runs but no `http.send` or `timer.schedule` starts.
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

`TugboatTests` runs the bridge against the real engine (the
`fingerprint.labelHash` conformance fixture), the host with a fake engine and
transport, real timers, the multipart golden bytes shared with the Android
host (`conformance/host/multipart-request.golden`), and the HTTP executor against a `URLProtocol` stub.
`TugboatTests/SwiftUI` tests the adapter on hosted SwiftUI views in a test
window, including the layer-allowlist regression guard, which fails when a
screen with text and an image shows no allowlisted layer class on a verified
iOS major.
